import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { PrismaService } from '../../prisma/prisma.service';
import { AccountIdGenerator } from '../account-id.generator';
import { AuthService } from '../auth.service';
import { PasswordHasher, ScryptPasswordHasher } from '../password.hasher';
import { LoginWithEmailUseCase } from './login-with-email.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const NOW = new Date('2026-08-01T00:00:00.000Z');
const PASSWORD = 'correct horse battery';

const ENV: Record<string, string> = {
  JWT_ACCESS_SECRET: 'test-access-secret',
  JWT_ACCESS_TTL_SECONDS: '3600',
  REFRESH_TTL_DAYS: '30',
};

interface PrismaMock {
  user: { findUnique: jest.Mock; update: jest.Mock };
  refreshToken: { create: jest.Mock };
  $transaction: jest.Mock;
}

describe('LoginWithEmailUseCase', () => {
  let prisma: PrismaMock;
  let hasher: PasswordHasher;
  let verifySpy: jest.SpyInstance;
  let useCase: LoginWithEmailUseCase;
  let storedHash: string;

  beforeAll(async () => {
    storedHash = await new ScryptPasswordHasher({ N: 1024, r: 8, p: 1 }).hash(
      PASSWORD,
    );
  });

  function userRow(overrides: Record<string, unknown> = {}) {
    return {
      id: USER_ID,
      email: 'fan@example.com',
      emailNormalized: 'fan@example.com',
      passwordHash: storedHash,
      appleSub: null,
      googleSub: null,
      profile: { accountId: 'ACC-3F9A21', displayName: 'ゆうや' },
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
      refreshToken: { create: jest.fn().mockResolvedValue(undefined) },
      $transaction: jest.fn(),
    };
    prisma.$transaction.mockImplementation((cb: (tx: PrismaMock) => unknown) =>
      Promise.resolve(cb(prisma)),
    );

    hasher = new ScryptPasswordHasher({ N: 1024, r: 8, p: 1 });
    verifySpy = jest.spyOn(hasher, 'verify');

    const service = new AuthService(
      prisma as unknown as PrismaService,
      {
        signAsync: jest.fn().mockResolvedValue('signed.access.token'),
      } as unknown as JwtService,
      { get: (key: string) => ENV[key] } as unknown as ConfigService,
      new AccountIdGenerator(),
      {
        get: jest.fn().mockResolvedValue({
          plan: 'free',
          expiresAt: null,
          inGracePeriod: false,
          bonusIdentitySlots: 0,
          bonusExpiresAt: null,
        }),
      } as unknown as EntitlementsService,
    );
    useCase = new LoginWithEmailUseCase(service, hasher);
  });

  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('AC-EP-07 正しい資格情報なら 200 相当のレスポンス（is_new は常に false）', async () => {
    const response = await useCase.execute({
      email: 'fan@example.com',
      password: PASSWORD,
    });

    expect(response).toEqual({
      access_token: 'signed.access.token',
      refresh_token: expect.any(String),
      expires_in: 3600,
      token_type: 'Bearer',
      user: {
        id: USER_ID,
        account_id: 'ACC-3F9A21',
        display_name: 'ゆうや',
        plan: 'free',
        is_new: false,
      },
    });
  });

  it('AC-EP-03 検索は正規化 email で行う（大小・空白違いでもログインできる）', async () => {
    await useCase.execute({ email: ' FAN@Example.com ', password: PASSWORD });

    expect(prisma.user.findUnique).toHaveBeenCalledWith({
      where: { emailNormalized: 'fan@example.com' },
    });
  });

  it('AC-EP-08 未登録 email は AUTH_CREDENTIALS_INVALID 401（固定メッセージ）', async () => {
    prisma.user.findUnique.mockResolvedValue(null);

    await expect(
      useCase.execute({ email: 'nobody@example.com', password: PASSWORD }),
    ).rejects.toMatchObject({
      code: 'AUTH_CREDENTIALS_INVALID',
      status: 401,
      message: 'invalid email or password',
    });
  });

  it('AC-EP-08 パスワード誤りは未登録と完全に同じ code / message / status', async () => {
    await expect(
      useCase.execute({ email: 'fan@example.com', password: 'wrong password' }),
    ).rejects.toMatchObject({
      code: 'AUTH_CREDENTIALS_INVALID',
      status: 401,
      message: 'invalid email or password',
    });
  });

  it('AC-EP-08 password_hash が null（Apple / Google のみ）も同じ 401', async () => {
    prisma.user.findUnique.mockResolvedValue(
      userRow({ passwordHash: null, appleSub: 'apple-sub' }),
    );

    await expect(
      useCase.execute({ email: 'fan@example.com', password: PASSWORD }),
    ).rejects.toMatchObject({
      code: 'AUTH_CREDENTIALS_INVALID',
      status: 401,
      message: 'invalid email or password',
    });
    expect(prisma.refreshToken.create).not.toHaveBeenCalled();
  });

  it('AC-EP-09 ユーザー不在でもハッシュ照合が 1 回実行される', async () => {
    prisma.user.findUnique.mockResolvedValue(null);

    await expect(
      useCase.execute({ email: 'nobody@example.com', password: PASSWORD }),
    ).rejects.toMatchObject({ code: 'AUTH_CREDENTIALS_INVALID' });

    expect(verifySpy).toHaveBeenCalledTimes(1);
    expect(verifySpy).toHaveBeenCalledWith(PASSWORD, null);
  });

  it('AC-EP-10 保存パラメータが現行既定と違えば再ハッシュして保存する', async () => {
    // 既定 (N=32768,r=8,p=3) の hasher から見ると N=1024 のハッシュは古い
    const current = new ScryptPasswordHasher();
    const service = new AuthService(
      prisma as unknown as PrismaService,
      {
        signAsync: jest.fn().mockResolvedValue('signed.access.token'),
      } as unknown as JwtService,
      { get: (key: string) => ENV[key] } as unknown as ConfigService,
      new AccountIdGenerator(),
      {
        get: jest.fn().mockResolvedValue({
          plan: 'free',
          expiresAt: null,
          inGracePeriod: false,
          bonusIdentitySlots: 0,
          bonusExpiresAt: null,
        }),
      } as unknown as EntitlementsService,
    );

    await new LoginWithEmailUseCase(service, current).execute({
      email: 'fan@example.com',
      password: PASSWORD,
    });

    expect(prisma.user.update).toHaveBeenCalledTimes(1);
    const call = prisma.user.update.mock.calls[0][0] as {
      where: { id: string };
      data: { passwordHash: string };
    };
    expect(call.where).toEqual({ id: USER_ID });
    expect(call.data.passwordHash).toMatch(/^scrypt\$N=32768,r=8,p=3\$/);
    expect(call.data.passwordHash).not.toContain(PASSWORD);
  });

  it('AC-EP-10 既定と同じパラメータなら再ハッシュしない', async () => {
    await useCase.execute({ email: 'fan@example.com', password: PASSWORD });

    expect(prisma.user.update).not.toHaveBeenCalled();
  });
});
