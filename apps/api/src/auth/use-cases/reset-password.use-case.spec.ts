import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { sha256Hex } from '../../common/util/hash.util';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { PrismaService } from '../../prisma/prisma.service';
import { AccountIdGenerator } from '../account-id.generator';
import { AuthService } from '../auth.service';
import { ScryptPasswordHasher } from '../password.hasher';
import { RESET_CODE_MAX_ATTEMPTS } from '../reset-code.generator';
import { ResetPasswordUseCase } from './reset-password.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const CODE_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';
const CODE = '04821093';
const NEW_PASSWORD = 'a brand new one';
const NOW = new Date('2026-08-01T00:00:00.000Z');
const TTL_MS = 15 * 60 * 1000;

const ENV: Record<string, string> = {
  JWT_ACCESS_SECRET: 'test-access-secret',
  JWT_ACCESS_TTL_SECONDS: '3600',
  REFRESH_TTL_DAYS: '30',
};

const INVALID = {
  code: 'AUTH_RESET_CODE_INVALID',
  status: 401,
  message: 'invalid or expired reset code',
};

interface PrismaMock {
  user: { findUnique: jest.Mock; update: jest.Mock };
  passwordResetCode: {
    findUnique: jest.Mock;
    findFirst: jest.Mock;
    update: jest.Mock;
    updateMany: jest.Mock;
  };
  refreshToken: { create: jest.Mock; updateMany: jest.Mock };
  $transaction: jest.Mock;
}

describe('ResetPasswordUseCase', () => {
  let prisma: PrismaMock;
  let useCase: ResetPasswordUseCase;
  const hasher = new ScryptPasswordHasher({ N: 1024, r: 8, p: 1 });

  function userRow(overrides: Record<string, unknown> = {}) {
    return {
      id: USER_ID,
      email: 'fan@example.com',
      emailNormalized: 'fan@example.com',
      passwordHash: 'scrypt$N=1024,r=8,p=1$aaaa$bbbb',
      profile: { accountId: 'ACC-3F9A21', displayName: 'ゆうや' },
      ...overrides,
    };
  }

  function codeRow(overrides: Record<string, unknown> = {}) {
    return {
      id: CODE_ID,
      userId: USER_ID,
      codeHash: sha256Hex(`${USER_ID}:${CODE}`),
      expiresAt: new Date(NOW.getTime() + TTL_MS),
      usedAt: null,
      attemptCount: 0,
      createdAt: NOW,
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
      passwordResetCode: {
        findUnique: jest.fn().mockResolvedValue(codeRow()),
        findFirst: jest.fn().mockResolvedValue(codeRow()),
        update: jest.fn().mockResolvedValue(undefined),
        updateMany: jest.fn().mockResolvedValue({ count: 1 }),
      },
      refreshToken: {
        create: jest.fn().mockResolvedValue(undefined),
        updateMany: jest.fn().mockResolvedValue({ count: 3 }),
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
    useCase = new ResetPasswordUseCase(service, hasher);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  function submit(overrides: Record<string, string> = {}) {
    return useCase.execute({
      email: 'fan@example.com',
      code: CODE,
      new_password: NEW_PASSWORD,
      ...overrides,
    });
  }

  it('AC-PR-07 成功時は login と同形のレスポンス（is_new: false）', async () => {
    const response = await submit();

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

  it('AC-PR-04 コードはハッシュで引く（平文で DB を検索しない）', async () => {
    await submit();

    expect(prisma.passwordResetCode.findUnique).toHaveBeenCalledWith({
      where: { codeHash: sha256Hex(`${USER_ID}:${CODE}`) },
    });
  });

  it('AC-PR-07 password_hash / password_updated_at を更新し、平文を保存しない', async () => {
    await submit();

    const call = prisma.user.update.mock.calls[0][0] as {
      where: { id: string };
      data: { passwordHash: string; passwordUpdatedAt: Date };
    };
    expect(call.where).toEqual({ id: USER_ID });
    expect(call.data.passwordHash).toMatch(/^scrypt\$N=\d+,r=\d+,p=\d+\$/);
    expect(call.data.passwordHash).not.toContain(NEW_PASSWORD);
    expect(call.data.passwordUpdatedAt).toEqual(NOW);
  });

  it('AC-PR-08 同一 TX でコード使用済み・他コード失効・refresh 全件失効を行う', async () => {
    const response = await submit();

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.passwordResetCode.updateMany).toHaveBeenCalledWith({
      where: { userId: USER_ID, usedAt: null },
      data: { usedAt: NOW },
    });
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
  });

  it('AC-PR-09 未知 email は AUTH_RESET_CODE_INVALID 401（固定メッセージ）', async () => {
    prisma.user.findUnique.mockResolvedValue(null);

    await expect(submit()).rejects.toMatchObject(INVALID);
    expect(prisma.user.update).not.toHaveBeenCalled();
    expect(prisma.refreshToken.create).not.toHaveBeenCalled();
  });

  it('AC-PR-09 password_hash が null のアカウントも同じ 401', async () => {
    prisma.user.findUnique.mockResolvedValue(
      userRow({ passwordHash: null, appleSub: 'apple-sub' }),
    );

    await expect(submit()).rejects.toMatchObject(INVALID);
  });

  it('AC-PR-09 誤コード（該当行なし）は同じ 401 で、試行を 1 回数える', async () => {
    prisma.passwordResetCode.findUnique.mockResolvedValue(null);

    await expect(submit({ code: '99999999' })).rejects.toMatchObject(INVALID);

    expect(prisma.passwordResetCode.update).toHaveBeenCalledWith({
      where: { id: CODE_ID },
      data: { attemptCount: 1 },
    });
    expect(prisma.user.update).not.toHaveBeenCalled();
  });

  it('AC-PR-09 期限切れ（15 分ちょうどを含む）は同じ 401', async () => {
    prisma.passwordResetCode.findUnique.mockResolvedValue(
      codeRow({ expiresAt: NOW }),
    );

    await expect(submit()).rejects.toMatchObject(INVALID);
    expect(prisma.user.update).not.toHaveBeenCalled();
  });

  it('AC-PR-09 使用済みコードは同じ 401', async () => {
    prisma.passwordResetCode.findUnique.mockResolvedValue(
      codeRow({ usedAt: new Date(NOW.getTime() - 1000) }),
    );

    await expect(submit()).rejects.toMatchObject(INVALID);
  });

  it('AC-PR-09 他ユーザーのコード行が引けても使わせない', async () => {
    prisma.passwordResetCode.findUnique.mockResolvedValue(
      codeRow({ userId: '018f3c2a-9999-7c90-9d2a-000000000002' }),
    );

    await expect(submit()).rejects.toMatchObject(INVALID);
    expect(prisma.user.update).not.toHaveBeenCalled();
  });

  it('AC-PR-10 誤り 5 回目でそのコードを失効させる', async () => {
    prisma.passwordResetCode.findUnique.mockResolvedValue(null);
    prisma.passwordResetCode.findFirst.mockResolvedValue(
      codeRow({ attemptCount: RESET_CODE_MAX_ATTEMPTS - 1 }),
    );

    await expect(submit({ code: '99999999' })).rejects.toMatchObject(INVALID);

    expect(prisma.passwordResetCode.update).toHaveBeenCalledWith({
      where: { id: CODE_ID },
      data: { attemptCount: RESET_CODE_MAX_ATTEMPTS, usedAt: NOW },
    });
  });

  it('AC-PR-10 試行超過済みのコードは正しくても 401', async () => {
    prisma.passwordResetCode.findUnique.mockResolvedValue(
      codeRow({ attemptCount: RESET_CODE_MAX_ATTEMPTS }),
    );

    await expect(submit()).rejects.toMatchObject(INVALID);
    expect(prisma.user.update).not.toHaveBeenCalled();
  });

  it('AC-PR-09 有効なコードが 1 本も無ければ試行記録も行わない（例外にしない）', async () => {
    prisma.passwordResetCode.findUnique.mockResolvedValue(null);
    prisma.passwordResetCode.findFirst.mockResolvedValue(null);

    await expect(submit({ code: '99999999' })).rejects.toMatchObject(INVALID);
    expect(prisma.passwordResetCode.update).not.toHaveBeenCalled();
  });
});
