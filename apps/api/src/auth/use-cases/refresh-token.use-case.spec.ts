import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { PrismaService } from '../../prisma/prisma.service';
import { AppError } from '../../common/errors/app-error';
import { sha256Hex } from '../../common/util/hash.util';
import { AccountIdGenerator } from '../account-id.generator';
import { AuthService } from '../auth.service';
import { RefreshTokenUseCase } from './refresh-token.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OLD_TOKEN_ID = '018f3c2a-2222-7c90-9d2a-000000000001';
const RAW_TOKEN = 'raw-refresh-token';
const NOW = new Date('2026-08-01T00:00:00.000Z');
const DAY_MS = 24 * 60 * 60 * 1000;

const ENV: Record<string, string> = {
  JWT_ACCESS_SECRET: 'test-access-secret',
  JWT_ACCESS_TTL_SECONDS: '3600',
  REFRESH_TTL_DAYS: '30',
};

interface PrismaMock {
  refreshToken: {
    findUnique: jest.Mock;
    create: jest.Mock;
    updateMany: jest.Mock;
  };
  $transaction: jest.Mock;
}

function storedRow(overrides: Record<string, unknown> = {}) {
  return {
    id: OLD_TOKEN_ID,
    userId: USER_ID,
    tokenHash: sha256Hex(RAW_TOKEN),
    expiresAt: new Date(NOW.getTime() + 10 * DAY_MS),
    revokedAt: null,
    replacedBy: null,
    createdAt: new Date(NOW.getTime() - DAY_MS),
    ...overrides,
  };
}

describe('RefreshTokenUseCase', () => {
  let prisma: PrismaMock;
  let useCase: RefreshTokenUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      refreshToken: {
        findUnique: jest.fn().mockResolvedValue(storedRow()),
        create: jest.fn().mockResolvedValue(undefined),
        updateMany: jest.fn().mockResolvedValue({ count: 1 }),
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
    useCase = new RefreshTokenUseCase(service);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('AC-AUTH-06 旧トークンを revoked_at にし、新しい access + refresh を返す', async () => {
    const response = await useCase.execute({ refresh_token: RAW_TOKEN });

    expect(prisma.refreshToken.findUnique).toHaveBeenCalledWith({
      where: { tokenHash: sha256Hex(RAW_TOKEN) },
    });

    const revoke = prisma.refreshToken.updateMany.mock.calls[0][0] as {
      where: Record<string, unknown>;
      data: Record<string, unknown>;
    };
    expect(revoke.where).toEqual({ id: OLD_TOKEN_ID, revokedAt: null });
    expect(revoke.data.revokedAt).toEqual(NOW);
    expect(revoke.data.replacedBy).toEqual(expect.any(String));

    expect(response).toEqual({
      access_token: 'signed.access.token',
      refresh_token: expect.any(String),
      expires_in: 3600,
      token_type: 'Bearer',
    });
    expect(response.refresh_token).not.toBe(RAW_TOKEN);

    const created = prisma.refreshToken.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(created.id).toBe(revoke.data.replacedBy);
    expect(created.userId).toBe(USER_ID);
    expect(created.tokenHash).toBe(sha256Hex(response.refresh_token));
    expect(created.expiresAt).toEqual(new Date(NOW.getTime() + 30 * DAY_MS));
  });

  it('AC-AUTH-07 未知の refresh token は AUTH_REFRESH_INVALID 401', async () => {
    prisma.refreshToken.findUnique.mockResolvedValue(null);

    await expect(
      useCase.execute({ refresh_token: 'unknown' }),
    ).rejects.toMatchObject({ code: 'AUTH_REFRESH_INVALID' });
    expect(prisma.refreshToken.updateMany).not.toHaveBeenCalled();
    expect(prisma.refreshToken.create).not.toHaveBeenCalled();

    try {
      await useCase.execute({ refresh_token: 'unknown' });
      fail('should throw');
    } catch (error) {
      expect(error).toBeInstanceOf(AppError);
      expect((error as AppError).getStatus()).toBe(401);
    }
  });

  it('AC-AUTH-07 失効済み refresh token は AUTH_REFRESH_INVALID 401', async () => {
    prisma.refreshToken.findUnique.mockResolvedValue(
      storedRow({ revokedAt: new Date(NOW.getTime() - 1000) }),
    );

    await expect(
      useCase.execute({ refresh_token: RAW_TOKEN }),
    ).rejects.toMatchObject({ code: 'AUTH_REFRESH_INVALID' });
    expect(prisma.refreshToken.create).not.toHaveBeenCalled();
  });

  it('AC-AUTH-07 期限切れ refresh token は AUTH_REFRESH_INVALID 401', async () => {
    prisma.refreshToken.findUnique.mockResolvedValue(
      storedRow({ expiresAt: new Date(NOW.getTime() - 1000) }),
    );

    await expect(
      useCase.execute({ refresh_token: RAW_TOKEN }),
    ).rejects.toMatchObject({ code: 'AUTH_REFRESH_INVALID' });
  });

  it('AC-AUTH-07 有効期限ちょうどは無効として 401', async () => {
    prisma.refreshToken.findUnique.mockResolvedValue(
      storedRow({ expiresAt: NOW }),
    );

    await expect(
      useCase.execute({ refresh_token: RAW_TOKEN }),
    ).rejects.toMatchObject({ code: 'AUTH_REFRESH_INVALID' });
  });

  it('AC-AUTH-07 同時使用は先勝ち。後発は 401 で新トークンを発行しない (E-13)', async () => {
    prisma.refreshToken.updateMany.mockResolvedValue({ count: 0 });

    await expect(
      useCase.execute({ refresh_token: RAW_TOKEN }),
    ).rejects.toMatchObject({ code: 'AUTH_REFRESH_INVALID' });
    expect(prisma.refreshToken.create).not.toHaveBeenCalled();
  });
});
