import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { sha256Hex } from '../../common/util/hash.util';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { PrismaService } from '../../prisma/prisma.service';
import { AccountIdGenerator } from '../account-id.generator';
import { AuthService } from '../auth.service';
import { ScryptPasswordHasher } from '../password.hasher';
import { ChangePasswordUseCase } from './change-password.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const NOW = new Date('2026-08-01T00:00:00.000Z');
const CURRENT = 'correct horse battery';
const NEXT = 'a brand new one';

const ENV: Record<string, string> = {
  JWT_ACCESS_SECRET: 'test-access-secret',
  JWT_ACCESS_TTL_SECONDS: '3600',
  REFRESH_TTL_DAYS: '30',
};

interface PrismaMock {
  user: { findUnique: jest.Mock; update: jest.Mock };
  refreshToken: { create: jest.Mock; updateMany: jest.Mock };
  $transaction: jest.Mock;
}

describe('ChangePasswordUseCase', () => {
  let prisma: PrismaMock;
  let useCase: ChangePasswordUseCase;
  let storedHash: string;
  const hasher = new ScryptPasswordHasher({ N: 1024, r: 8, p: 1 });

  beforeAll(async () => {
    storedHash = await hasher.hash(CURRENT);
  });

  function userRow(overrides: Record<string, unknown> = {}) {
    return {
      id: USER_ID,
      email: 'fan@example.com',
      emailNormalized: 'fan@example.com',
      passwordHash: storedHash,
      ...overrides,
    };
  }

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      user: {
        findUnique: jest.fn().mockResolvedValue(userRow()),
        update: jest.fn().mockResolvedValue(undefined),
      },
      refreshToken: {
        create: jest.fn().mockResolvedValue(undefined),
        updateMany: jest.fn().mockResolvedValue({ count: 2 }),
      },
      $transaction: jest.fn(),
    };
    prisma.$transaction.mockImplementation((cb: (tx: PrismaMock) => unknown) =>
      Promise.resolve(cb(prisma)),
    );

    const service = new AuthService(
      prisma as unknown as PrismaService,
      {
        signAsync: jest.fn().mockResolvedValue('signed.access.token'),
      } as unknown as JwtService,
      { get: (key: string) => ENV[key] } as unknown as ConfigService,
      new AccountIdGenerator(),
      { get: jest.fn() } as unknown as EntitlementsService,
    );
    useCase = new ChangePasswordUseCase(service, hasher);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('AC-EP-11 正しい current なら TokenPairResponse を返す（user ブロックは無い）', async () => {
    const response = await useCase.execute(USER_ID, {
      current_password: CURRENT,
      new_password: NEXT,
    });

    expect(response).toEqual({
      access_token: 'signed.access.token',
      refresh_token: expect.any(String),
      expires_in: 3600,
      token_type: 'Bearer',
    });
  });

  it('AC-EP-11 既存 refresh を全件失効させ、新しい 1 本を同一 TX で作る', async () => {
    const response = await useCase.execute(USER_ID, {
      current_password: CURRENT,
      new_password: NEXT,
    });

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.refreshToken.updateMany).toHaveBeenCalledWith({
      where: { userId: USER_ID, revokedAt: null },
      data: { revokedAt: NOW },
    });

    const created = prisma.refreshToken.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(created.userId).toBe(USER_ID);
    expect(created.tokenHash).toBe(sha256Hex(response.refresh_token));
    expect(JSON.stringify(created)).not.toContain(response.refresh_token);
  });

  it('AC-EP-11 password_hash と password_updated_at を更新する（平文は保存しない）', async () => {
    await useCase.execute(USER_ID, {
      current_password: CURRENT,
      new_password: NEXT,
    });

    const call = prisma.user.update.mock.calls[0][0] as {
      where: { id: string };
      data: { passwordHash: string; passwordUpdatedAt: Date };
    };
    expect(call.where).toEqual({ id: USER_ID });
    expect(call.data.passwordHash).toMatch(/^scrypt\$N=\d+,r=\d+,p=\d+\$/);
    expect(call.data.passwordHash).not.toContain(NEXT);
    expect(call.data.passwordUpdatedAt).toEqual(NOW);
  });

  it('AC-EP-12 current 不一致は AUTH_CREDENTIALS_INVALID 401 で DB を変更しない', async () => {
    await expect(
      useCase.execute(USER_ID, {
        current_password: 'wrong password',
        new_password: NEXT,
      }),
    ).rejects.toMatchObject({
      code: 'AUTH_CREDENTIALS_INVALID',
      status: 401,
      message: 'invalid email or password',
    });

    expect(prisma.user.update).not.toHaveBeenCalled();
    expect(prisma.refreshToken.updateMany).not.toHaveBeenCalled();
  });

  it('AC-EP-12 password_hash が null なら FORBIDDEN 403', async () => {
    prisma.user.findUnique.mockResolvedValue(
      userRow({ passwordHash: null, appleSub: 'apple-sub' }),
    );

    await expect(
      useCase.execute(USER_ID, {
        current_password: CURRENT,
        new_password: NEXT,
      }),
    ).rejects.toMatchObject({ code: 'FORBIDDEN', status: 403 });

    expect(prisma.user.update).not.toHaveBeenCalled();
  });

  it('AC-EP-12 current === new は VALIDATION_ERROR 400（照合前に弾く）', async () => {
    await expect(
      useCase.execute(USER_ID, {
        current_password: CURRENT,
        new_password: CURRENT,
      }),
    ).rejects.toMatchObject({ code: 'VALIDATION_ERROR', status: 400 });

    expect(prisma.user.findUnique).not.toHaveBeenCalled();
    expect(prisma.user.update).not.toHaveBeenCalled();
  });

  it('ユーザーが消えていたら UNAUTHENTICATED 401', async () => {
    prisma.user.findUnique.mockResolvedValue(null);

    await expect(
      useCase.execute(USER_ID, {
        current_password: CURRENT,
        new_password: NEXT,
      }),
    ).rejects.toMatchObject({ code: 'UNAUTHENTICATED', status: 401 });
  });
});
