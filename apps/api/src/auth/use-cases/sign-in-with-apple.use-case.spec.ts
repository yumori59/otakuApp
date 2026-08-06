import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { PrismaService } from '../../prisma/prisma.service';
import { sha256Hex } from '../../common/util/hash.util';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AccountIdGenerator } from '../account-id.generator';
import { AppleTokenVerifier } from '../apple-token.verifier';
import { AuthService } from '../auth.service';
import { SignInWithAppleUseCase } from './sign-in-with-apple.use-case';

const APPLE_SUB = '001234.abcdef0123456789.0000';
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

describe('SignInWithAppleUseCase', () => {
  let prisma: PrismaMock;
  let verify: jest.Mock;
  let entitlementsGet: jest.Mock;
  let useCase: SignInWithAppleUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = createPrismaMock();
    verify = jest.fn().mockResolvedValue({
      sub: APPLE_SUB,
      email: 'abc@privaterelay.appleid.com',
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

    useCase = new SignInWithAppleUseCase(
      { verify } as unknown as AppleTokenVerifier,
      service,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('AC-AUTH-01 新規ユーザーは user / profile(account_id) / entitlement(free) が同一 TX で作られる', async () => {
    const response = await useCase.execute({
      identity_token: 'apple.identity.token',
    });

    expect(verify).toHaveBeenCalledWith('apple.identity.token', undefined);
    expect(prisma.user.findUnique).toHaveBeenCalledWith({
      where: { appleSub: APPLE_SUB },
      include: { profile: true },
    });
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);

    const userData = prisma.user.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(userData.id).toMatch(UUID_PATTERN);
    expect(userData.appleSub).toBe(APPLE_SUB);
    expect(userData.email).toBe('abc@privaterelay.appleid.com');

    const profileData = prisma.profile.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(profileData.id).toBe(userData.id);
    expect(profileData.accountId).toMatch(/^ACC-[0-9A-F]{6}$/);

    expect(prisma.entitlement.create).toHaveBeenCalledWith({
      data: { userId: userData.id, plan: 'free' },
    });

    expect(response).toEqual({
      access_token: 'signed.access.token',
      refresh_token: expect.any(String),
      expires_in: 3600,
      token_type: 'Bearer',
      user: {
        id: userData.id,
        account_id: profileData.accountId,
        display_name: null,
        plan: 'free',
        is_new: true,
      },
    });
  });

  it('AC-AUTH-01 発行した refresh token は sha256 のみ保存される (AC-AUTH-05)', async () => {
    const response = await useCase.execute({
      identity_token: 'apple.identity.token',
    });

    const data = prisma.refreshToken.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(data.tokenHash).toBe(sha256Hex(response.refresh_token));
    expect(JSON.stringify(data)).not.toContain(response.refresh_token);
  });

  it('AC-AUTH-02 既存 apple_sub の再ログインはユーザーを重複作成せず is_new: false', async () => {
    prisma.user.findUnique.mockResolvedValue({
      id: EXISTING_USER_ID,
      appleSub: APPLE_SUB,
      email: 'abc@privaterelay.appleid.com',
      profile: { accountId: 'ACC-3F9A21', displayName: 'ゆうや' },
    });

    const response = await useCase.execute({
      identity_token: 'apple.identity.token',
    });

    expect(prisma.$transaction).not.toHaveBeenCalled();
    expect(prisma.user.create).not.toHaveBeenCalled();
    expect(prisma.profile.create).not.toHaveBeenCalled();
    expect(prisma.entitlement.create).not.toHaveBeenCalled();
    expect(response.user).toEqual({
      id: EXISTING_USER_ID,
      account_id: 'ACC-3F9A21',
      display_name: 'ゆうや',
      plan: 'free',
      is_new: false,
    });
    expect(response.access_token).toBe('signed.access.token');
    expect(response.refresh_token).toEqual(expect.any(String));
  });

  it('AC-AUTH-02 既存ユーザーの plan は entitlement から返す', async () => {
    prisma.user.findUnique.mockResolvedValue({
      id: EXISTING_USER_ID,
      appleSub: APPLE_SUB,
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

    const response = await useCase.execute({
      identity_token: 'apple.identity.token',
    });

    expect(entitlementsGet).toHaveBeenCalledWith(EXISTING_USER_ID);
    expect(response.user.plan).toBe('plus');
  });

  it('AC-AUTH-09 email は初回のみ保存し、2 回目以降 null が来ても既存値を上書きしない', async () => {
    prisma.user.findUnique.mockResolvedValue({
      id: EXISTING_USER_ID,
      appleSub: APPLE_SUB,
      email: 'abc@privaterelay.appleid.com',
      profile: { accountId: 'ACC-3F9A21', displayName: null },
    });
    verify.mockResolvedValue({ sub: APPLE_SUB, email: null });

    await useCase.execute({ identity_token: 'apple.identity.token' });

    expect(prisma.user.update).not.toHaveBeenCalled();
  });

  it('AC-AUTH-09 既存ユーザーに email が再送されても更新しない', async () => {
    prisma.user.findUnique.mockResolvedValue({
      id: EXISTING_USER_ID,
      appleSub: APPLE_SUB,
      email: 'first@privaterelay.appleid.com',
      profile: { accountId: 'ACC-3F9A21', displayName: null },
    });
    verify.mockResolvedValue({
      sub: APPLE_SUB,
      email: 'second@privaterelay.appleid.com',
    });

    await useCase.execute({ identity_token: 'apple.identity.token' });

    expect(prisma.user.update).not.toHaveBeenCalled();
  });

  it('AC-AUTH-09 email が無い初回サインインは email: null で作成する', async () => {
    verify.mockResolvedValue({ sub: APPLE_SUB, email: null });

    await useCase.execute({ identity_token: 'apple.identity.token' });

    const userData = prisma.user.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(userData.email).toBeNull();
  });

  it('AC-AUTH-03 token 検証に失敗したら DB に一切書き込まない', async () => {
    verify.mockRejectedValue(
      new AppError(ErrorCode.AUTH_APPLE_INVALID, 'invalid'),
    );

    await expect(
      useCase.execute({ identity_token: 'broken' }),
    ).rejects.toMatchObject({ code: 'AUTH_APPLE_INVALID' });

    expect(prisma.user.findUnique).not.toHaveBeenCalled();
    expect(prisma.$transaction).not.toHaveBeenCalled();
    expect(prisma.refreshToken.create).not.toHaveBeenCalled();
  });

  it('同一 apple_sub の同時初回サインインは先に作られた行を返す（is_new: false）', async () => {
    const existing = {
      id: EXISTING_USER_ID,
      appleSub: APPLE_SUB,
      email: 'abc@privaterelay.appleid.com',
      profile: { accountId: 'ACC-3F9A21', displayName: null },
    };
    prisma.user.findUnique
      .mockResolvedValueOnce(null)
      .mockResolvedValueOnce(existing);
    prisma.user.create.mockRejectedValue(
      Object.assign(new Error('Unique constraint failed'), {
        code: 'P2002',
        meta: { target: ['apple_sub'] },
      }),
    );

    const response = await useCase.execute({
      identity_token: 'apple.identity.token',
    });

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(response.user).toEqual({
      id: EXISTING_USER_ID,
      account_id: 'ACC-3F9A21',
      display_name: null,
      plan: 'free',
      is_new: false,
    });
  });

  it('AC-AUTH-04 nonce は verifier にそのまま渡す', async () => {
    await useCase.execute({
      identity_token: 'apple.identity.token',
      nonce: 'nonce-abc',
    });

    expect(verify).toHaveBeenCalledWith('apple.identity.token', 'nonce-abc');
  });
});
