import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { sha256Hex } from '../../common/util/hash.util';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { PrismaService } from '../../prisma/prisma.service';
import { AccountIdGenerator } from '../account-id.generator';
import { AuthService } from '../auth.service';
import { GoogleTokenVerifier } from '../google-token.verifier';
import { SignInWithGoogleUseCase } from './sign-in-with-google.use-case';

const GOOGLE_SUB = '107654321098765432109';
const EXISTING_USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const NOW = new Date('2026-08-01T00:00:00.000Z');
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const ENV: Record<string, string> = {
  JWT_ACCESS_SECRET: 'test-access-secret',
  JWT_ACCESS_TTL_SECONDS: '3600',
  REFRESH_TTL_DAYS: '30',
};

interface PrismaMock {
  user: { findUnique: jest.Mock; create: jest.Mock; update: jest.Mock };
  profile: { create: jest.Mock };
  entitlement: { create: jest.Mock; findUnique: jest.Mock };
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
      update: jest.fn(),
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
      findUnique: jest.fn().mockResolvedValue(null),
    },
    refreshToken: { create: jest.fn().mockResolvedValue(undefined) },
    $transaction: jest.fn(),
  };
  prisma.$transaction.mockImplementation((cb: (tx: PrismaMock) => unknown) =>
    Promise.resolve(cb(prisma)),
  );
  return prisma;
}

describe('SignInWithGoogleUseCase', () => {
  let prisma: PrismaMock;
  let verify: jest.Mock;
  let entitlementsGet: jest.Mock;
  let useCase: SignInWithGoogleUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = createPrismaMock();
    verify = jest.fn().mockResolvedValue({
      sub: GOOGLE_SUB,
      email: 'fan@example.com',
    });
    entitlementsGet = jest.fn().mockResolvedValue({
      plan: 'free',
      expiresAt: null,
      inGracePeriod: false,
      bonusIdentitySlots: 0,
      bonusExpiresAt: null,
    });

    const service = new AuthService(
      prisma as unknown as PrismaService,
      {
        signAsync: jest.fn().mockResolvedValue('signed.access.token'),
      } as unknown as JwtService,
      { get: (key: string) => ENV[key] } as unknown as ConfigService,
      new AccountIdGenerator(),
      { get: entitlementsGet } as unknown as EntitlementsService,
    );

    useCase = new SignInWithGoogleUseCase(
      { verify } as unknown as GoogleTokenVerifier,
      service,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('AC-GA-01 新規ユーザーは user(google_sub) / profile / entitlement(free) を同一 TX で作る', async () => {
    const response = await useCase.execute({ id_token: 'google.id.token' });

    expect(verify).toHaveBeenCalledWith('google.id.token', undefined);
    expect(prisma.user.findUnique).toHaveBeenCalledWith({
      where: { googleSub: GOOGLE_SUB },
      include: { profile: true },
    });
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);

    const userData = prisma.user.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(userData.id).toMatch(UUID_PATTERN);
    expect(userData.googleSub).toBe(GOOGLE_SUB);
    expect(userData.appleSub).toBeUndefined();
    expect(userData.email).toBe('fan@example.com');

    const profileData = prisma.profile.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(profileData.id).toBe(userData.id);
    expect(profileData.accountId).toMatch(/^ACC-[0-9A-F]{6}$/);

    expect(prisma.entitlement.create).toHaveBeenCalledWith({
      data: { userId: userData.id, plan: 'free' },
    });

    expect(response.user.is_new).toBe(true);
  });

  it('AC-GA-13 レスポンスのキーは POST /v1/auth/apple と完全一致', async () => {
    const response = await useCase.execute({ id_token: 'google.id.token' });

    expect(Object.keys(response).sort()).toEqual([
      'access_token',
      'expires_in',
      'refresh_token',
      'token_type',
      'user',
    ]);
    expect(Object.keys(response.user).sort()).toEqual([
      'account_id',
      'display_name',
      'id',
      'is_new',
      'plan',
    ]);
    expect(response.token_type).toBe('Bearer');
    expect(response.expires_in).toBe(3600);
    expect(response.access_token).toBe('signed.access.token');
  });

  it('AC-GA-01 発行した refresh token は sha256 のみ保存される', async () => {
    const response = await useCase.execute({ id_token: 'google.id.token' });

    const data = prisma.refreshToken.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(data.tokenHash).toBe(sha256Hex(response.refresh_token));
    expect(JSON.stringify(data)).not.toContain(response.refresh_token);
  });

  it('AC-GA-02 既存 google_sub の再サインインは行を増やさず is_new: false', async () => {
    prisma.user.findUnique.mockResolvedValue({
      id: EXISTING_USER_ID,
      googleSub: GOOGLE_SUB,
      email: 'fan@example.com',
      profile: { accountId: 'ACC-3F9A21', displayName: 'ゆうや' },
    });

    const response = await useCase.execute({ id_token: 'google.id.token' });

    expect(prisma.$transaction).not.toHaveBeenCalled();
    expect(prisma.user.create).not.toHaveBeenCalled();
    expect(prisma.profile.create).not.toHaveBeenCalled();
    expect(response.user).toEqual({
      id: EXISTING_USER_ID,
      account_id: 'ACC-3F9A21',
      display_name: 'ゆうや',
      plan: 'free',
      is_new: false,
    });
  });

  it('AC-GA-09 既存ユーザーの email は上書きしない', async () => {
    prisma.user.findUnique.mockResolvedValue({
      id: EXISTING_USER_ID,
      googleSub: GOOGLE_SUB,
      email: 'first@example.com',
      profile: { accountId: 'ACC-3F9A21', displayName: null },
    });
    verify.mockResolvedValue({ sub: GOOGLE_SUB, email: 'second@example.com' });

    await useCase.execute({ id_token: 'google.id.token' });

    expect(prisma.user.update).not.toHaveBeenCalled();
  });

  it('AC-GA-09 email_verified でない（verifier が null を返す）なら email を保存しない', async () => {
    verify.mockResolvedValue({ sub: GOOGLE_SUB, email: null });

    await useCase.execute({ id_token: 'google.id.token' });

    const userData = prisma.user.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(userData.email).toBeNull();
  });

  it('AC-GA-02 既存ユーザーの plan は entitlement から返す', async () => {
    prisma.user.findUnique.mockResolvedValue({
      id: EXISTING_USER_ID,
      googleSub: GOOGLE_SUB,
      email: null,
      profile: { accountId: 'ACC-3F9A21', displayName: null },
    });
    entitlementsGet.mockResolvedValue({
      plan: 'plus',
      expiresAt: null,
      inGracePeriod: false,
      bonusIdentitySlots: 0,
      bonusExpiresAt: null,
    });

    const response = await useCase.execute({ id_token: 'google.id.token' });

    expect(entitlementsGet).toHaveBeenCalledWith(EXISTING_USER_ID);
    expect(response.user.plan).toBe('plus');
  });

  it('AC-GA-03 token 検証に失敗したら DB に一切書き込まない', async () => {
    verify.mockRejectedValue(
      new AppError(ErrorCode.AUTH_GOOGLE_INVALID, 'invalid'),
    );

    await expect(
      useCase.execute({ id_token: 'broken' }),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });

    expect(prisma.user.findUnique).not.toHaveBeenCalled();
    expect(prisma.$transaction).not.toHaveBeenCalled();
    expect(prisma.refreshToken.create).not.toHaveBeenCalled();
  });

  it('AC-GA-12 同時初回サインインの P2002 は 500 にせず読み直して is_new: false', async () => {
    prisma.user.findUnique.mockResolvedValueOnce(null).mockResolvedValueOnce({
      id: EXISTING_USER_ID,
      googleSub: GOOGLE_SUB,
      email: 'fan@example.com',
      profile: { accountId: 'ACC-3F9A21', displayName: null },
    });
    prisma.user.create.mockRejectedValue(
      Object.assign(new Error('Unique constraint failed'), {
        code: 'P2002',
        meta: { target: ['google_sub'] },
      }),
    );

    const response = await useCase.execute({ id_token: 'google.id.token' });

    expect(response.user).toEqual({
      id: EXISTING_USER_ID,
      account_id: 'ACC-3F9A21',
      display_name: null,
      plan: 'free',
      is_new: false,
    });
  });

  it('AC-GA-07 nonce は verifier にそのまま渡す', async () => {
    await useCase.execute({ id_token: 'google.id.token', nonce: 'nonce-abc' });

    expect(verify).toHaveBeenCalledWith('google.id.token', 'nonce-abc');
  });
});
