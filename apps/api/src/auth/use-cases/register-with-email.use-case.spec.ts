import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { sha256Hex } from '../../common/util/hash.util';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { PrismaService } from '../../prisma/prisma.service';
import { AccountIdGenerator } from '../account-id.generator';
import { AuthService } from '../auth.service';
import { ScryptPasswordHasher } from '../password.hasher';
import { RegisterWithEmailUseCase } from './register-with-email.use-case';

const NOW = new Date('2026-08-01T00:00:00.000Z');
const PASSWORD = 'correct horse battery';
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const ENV: Record<string, string> = {
  JWT_ACCESS_SECRET: 'test-access-secret',
  JWT_ACCESS_TTL_SECONDS: '3600',
  REFRESH_TTL_DAYS: '30',
};

interface PrismaMock {
  user: { findUnique: jest.Mock; create: jest.Mock };
  profile: { create: jest.Mock };
  entitlement: { create: jest.Mock };
  refreshToken: { create: jest.Mock };
  $transaction: jest.Mock;
}

function createPrismaMock(): PrismaMock {
  const prisma: PrismaMock = {
    user: {
      findUnique: jest.fn().mockResolvedValue(null),
      create: jest.fn(({ data }: { data: Record<string, unknown> }) =>
        Promise.resolve({ ...data }),
      ),
    },
    profile: {
      create: jest.fn(({ data }: { data: Record<string, unknown> }) =>
        Promise.resolve({ displayName: null, ...data }),
      ),
    },
    entitlement: {
      create: jest.fn(({ data }: { data: Record<string, unknown> }) =>
        Promise.resolve({ ...data }),
      ),
    },
    refreshToken: { create: jest.fn().mockResolvedValue(undefined) },
    $transaction: jest.fn(),
  };
  prisma.$transaction.mockImplementation((cb: (tx: PrismaMock) => unknown) =>
    Promise.resolve(cb(prisma)),
  );
  return prisma;
}

describe('RegisterWithEmailUseCase', () => {
  let prisma: PrismaMock;
  let useCase: RegisterWithEmailUseCase;
  // 既定パラメータは 1 回 100ms 程度かかるのでテストでは軽い設定を使う
  const hasher = new ScryptPasswordHasher({ N: 1024, r: 8, p: 1 });

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = createPrismaMock();

    const service = new AuthService(
      prisma as unknown as PrismaService,
      {
        signAsync: jest.fn().mockResolvedValue('signed.access.token'),
      } as unknown as JwtService,
      { get: (key: string) => ENV[key] } as unknown as ConfigService,
      new AccountIdGenerator(),
      { get: jest.fn() } as unknown as EntitlementsService,
    );
    useCase = new RegisterWithEmailUseCase(service, hasher);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  function userData(): Record<string, unknown> {
    return prisma.user.create.mock.calls[0][0].data as Record<string, unknown>;
  }

  it('AC-EP-01 user / profile(account_id) / entitlement(free) が同一 TX で作られ is_new: true', async () => {
    const response = await useCase.execute({
      email: 'fan@example.com',
      password: PASSWORD,
    });

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(userData().id).toMatch(UUID_PATTERN);

    const profileData = prisma.profile.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(profileData.id).toBe(userData().id);
    expect(profileData.accountId).toMatch(/^ACC-[0-9A-F]{6}$/);
    expect(prisma.entitlement.create).toHaveBeenCalledWith({
      data: { userId: userData().id, plan: 'free' },
    });

    expect(response).toEqual({
      access_token: 'signed.access.token',
      refresh_token: expect.any(String),
      expires_in: 3600,
      token_type: 'Bearer',
      user: {
        id: userData().id,
        account_id: profileData.accountId,
        display_name: null,
        plan: 'free',
        is_new: true,
      },
    });
  });

  it('AC-EP-02 password_hash は scrypt 形式で、平文が DB にもレスポンスにも現れない', async () => {
    const response = await useCase.execute({
      email: 'fan@example.com',
      password: PASSWORD,
    });

    expect(userData().passwordHash).toMatch(/^scrypt\$N=\d+,r=\d+,p=\d+\$/);
    expect(JSON.stringify(prisma.user.create.mock.calls)).not.toContain(
      PASSWORD,
    );
    expect(JSON.stringify(response)).not.toContain(PASSWORD);
    expect(userData().passwordUpdatedAt).toEqual(NOW);
  });

  it('AC-EP-03 email は入力どおり、email_normalized は trim + 小文字化して保存する', async () => {
    await useCase.execute({ email: 'Fan@Example.com', password: PASSWORD });

    expect(userData().email).toBe('Fan@Example.com');
    expect(userData().emailNormalized).toBe('fan@example.com');
    expect(prisma.user.findUnique).toHaveBeenCalledWith({
      where: { emailNormalized: 'fan@example.com' },
    });
  });

  it('AC-EP-04 既存の正規化 email なら EMAIL_ALREADY_REGISTERED 409 で DB に書かない', async () => {
    prisma.user.findUnique.mockResolvedValue({
      id: '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f',
      emailNormalized: 'fan@example.com',
    });

    await expect(
      useCase.execute({ email: 'FAN@example.com', password: PASSWORD }),
    ).rejects.toMatchObject({ code: 'EMAIL_ALREADY_REGISTERED' });

    expect(prisma.user.create).not.toHaveBeenCalled();
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('AC-EP-04 409 の HTTP ステータスは 409', async () => {
    prisma.user.findUnique.mockResolvedValue({ id: 'x' });

    await expect(
      useCase.execute({ email: 'fan@example.com', password: PASSWORD }),
    ).rejects.toMatchObject({ status: 409 });
  });

  it('AC-EP-05 同時 register の P2002 は 500 ではなく 409 になる（BE-6）', async () => {
    prisma.user.create.mockRejectedValue(
      Object.assign(new Error('Unique constraint failed'), {
        code: 'P2002',
        meta: { target: ['email_normalized'] },
      }),
    );

    await expect(
      useCase.execute({ email: 'fan@example.com', password: PASSWORD }),
    ).rejects.toMatchObject({ code: 'EMAIL_ALREADY_REGISTERED', status: 409 });
  });

  it('AC-EP-05 email_normalized 以外の P2002 はそのまま伝播させる（黙って 409 にしない）', async () => {
    prisma.user.create.mockRejectedValue(
      Object.assign(new Error('Unique constraint failed'), {
        code: 'P2002',
        meta: { target: ['some_other_column'] },
      }),
    );

    await expect(
      useCase.execute({ email: 'fan@example.com', password: PASSWORD }),
    ).rejects.not.toMatchObject({ code: 'EMAIL_ALREADY_REGISTERED' });
  });

  it('AC-EP-01 発行した refresh token は sha256 のみ保存される', async () => {
    const response = await useCase.execute({
      email: 'fan@example.com',
      password: PASSWORD,
    });

    const data = prisma.refreshToken.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(data.tokenHash).toBe(sha256Hex(response.refresh_token));
    expect(JSON.stringify(data)).not.toContain(response.refresh_token);
  });
});
