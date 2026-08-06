import { Prisma } from '@prisma/client';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { EntitlementsService } from '../entitlements/entitlements.service';
import { PrismaService } from '../prisma/prisma.service';
import { MeService } from './me.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const NOW = new Date('2026-08-01T00:00:00.000Z');

/**
 * `plan.md` §3.2 が定める削除順序（この配列を契約として扱う）。
 * applications は identities より前（applications.rep_identity_id が onDelete: Restrict のため）。
 */
const EXPECTED_DELETE_ORDER = [
  'applicationCompanion',
  'application',
  'membership',
  'identity',
  'event',
  'tour',
  'shareLink',
  'deviceToken',
  'refreshToken',
  'passwordResetCode',
  'entitlement',
  'profile',
  'user',
];

interface TxCall {
  model: string;
  method: string;
  where: Record<string, unknown>;
}

/** deleteMany / delete の呼び出し順と where を記録するトランザクションモック。 */
function buildTx(calls: TxCall[], failures: Record<string, unknown> = {}) {
  const tx: Record<string, unknown> = {};
  const register = (model: string, method: 'deleteMany' | 'delete') => {
    const existing = (tx[model] ?? {}) as Record<string, unknown>;
    existing[method] = jest.fn((args: { where: Record<string, unknown> }) => {
      calls.push({ model, method, where: args.where });
      const failure = failures[model];
      if (failure) return Promise.reject(failure);
      return Promise.resolve(method === 'deleteMany' ? { count: 0 } : {});
    });
    tx[model] = existing;
  };

  for (const model of EXPECTED_DELETE_ORDER) {
    register(model, model === 'user' ? 'delete' : 'deleteMany');
  }
  return tx;
}

function prismaP2025(): Prisma.PrismaClientKnownRequestError {
  return new Prisma.PrismaClientKnownRequestError(
    'An operation failed because it depends on one or more records that were required but not found.',
    { code: 'P2025', clientVersion: '6.19.0' },
  );
}

function userRow(overrides: Record<string, unknown> = {}) {
  return {
    id: USER_ID,
    appleSub: 'apple-sub-1',
    googleSub: null,
    passwordHash: null,
    email: 'abc@privaterelay.appleid.com',
    createdAt: NOW,
    updatedAt: NOW,
    profile: profileRow(),
    ...overrides,
  };
}

function profileRow(overrides: Record<string, unknown> = {}) {
  return {
    id: USER_ID,
    accountId: 'ACC-3F9A21',
    displayName: null,
    username: 'yuya',
    appDisplayName: '参戦名義帳',
    themeColor: '#0017C1',
    locale: 'ja_JP',
    timezone: 'Asia/Tokyo',
    onboardedAt: null,
    createdAt: NOW,
    updatedAt: NOW,
    ...overrides,
  };
}

function entitlementView(overrides: Record<string, unknown> = {}) {
  return {
    plan: 'free' as const,
    expiresAt: null,
    inGracePeriod: false,
    bonusIdentitySlots: 0,
    bonusExpiresAt: null,
    ...overrides,
  };
}

describe('MeService', () => {
  let prisma: {
    user: { findUnique: jest.Mock };
    profile: { update: jest.Mock };
    $transaction: jest.Mock;
  };
  let txCalls: TxCall[];
  let entitlements: {
    get: jest.Mock;
    identityLimit: jest.Mock;
    shareLimit: jest.Mock;
  };
  let service: MeService;

  beforeEach(() => {
    txCalls = [];
    prisma = {
      user: { findUnique: jest.fn() },
      profile: { update: jest.fn() },
      $transaction: jest.fn((callback: (tx: unknown) => Promise<unknown>) =>
        callback(buildTx(txCalls)),
      ),
    };
    entitlements = {
      get: jest.fn().mockResolvedValue(entitlementView()),
      identityLimit: jest.fn().mockResolvedValue(3),
      shareLimit: jest.fn().mockResolvedValue(1),
    };
    service = new MeService(
      prisma as unknown as PrismaService,
      entitlements as unknown as EntitlementsService,
    );
  });

  describe('getMe', () => {
    it('AC-ME-01 api-contract.md §2 の形で user/profile/entitlement を返す', async () => {
      prisma.user.findUnique.mockResolvedValue(userRow());

      const result = await service.getMe(USER_ID);

      expect(result).toEqual({
        user: {
          id: USER_ID,
          email: 'abc@privaterelay.appleid.com',
          auth_providers: ['apple'],
          created_at: NOW.toISOString(),
        },
        profile: {
          account_id: 'ACC-3F9A21',
          display_name: null,
          username: 'yuya',
          app_display_name: '参戦名義帳',
          theme_color: '#0017C1',
          locale: 'ja_JP',
          timezone: 'Asia/Tokyo',
          onboarded_at: null,
          created_at: NOW.toISOString(),
          updated_at: NOW.toISOString(),
        },
        entitlement: {
          plan: 'free',
          expires_at: null,
          in_grace_period: false,
          bonus_identity_slots: 0,
          bonus_expires_at: null,
          identity_limit: 3,
          share_limit: 1,
        },
      });
      expect(prisma.user.findUnique).toHaveBeenCalledWith({
        where: { id: USER_ID },
        include: { profile: true },
      });
    });

    it('AC-ME-02 apple_sub のみなら auth_providers=["apple"]', async () => {
      prisma.user.findUnique.mockResolvedValue(
        userRow({ appleSub: 'apple-sub-1', googleSub: null, email: null }),
      );
      const result = await service.getMe(USER_ID);
      expect(result.user.auth_providers).toEqual(['apple']);
    });

    it('AC-ME-02 apple_sub + email 列（連絡先のみ）があっても auth_providers=["apple"]（email 列は認証手段の判定に使わない）', async () => {
      prisma.user.findUnique.mockResolvedValue(
        userRow({
          appleSub: 'apple-sub-1',
          googleSub: null,
          passwordHash: null,
          email: 'a@example.com',
        }),
      );
      const result = await service.getMe(USER_ID);
      expect(result.user.auth_providers).toEqual(['apple']);
    });

    it('AC-EP-14 apple_sub / google_sub がどちらも無く password_hash のみなら auth_providers=["email"]', async () => {
      prisma.user.findUnique.mockResolvedValue(
        userRow({
          appleSub: null,
          googleSub: null,
          passwordHash: 'scrypt$...',
        }),
      );
      const result = await service.getMe(USER_ID);
      expect(result.user.auth_providers).toEqual(['email']);
    });

    it('AC-EP-14 apple_sub + google_sub + password_hash が全てあれば apple→google→email の順', async () => {
      prisma.user.findUnique.mockResolvedValue(
        userRow({
          appleSub: 'apple-sub-1',
          googleSub: 'google-sub-1',
          passwordHash: 'scrypt$...',
        }),
      );
      const result = await service.getMe(USER_ID);
      expect(result.user.auth_providers).toEqual(['apple', 'google', 'email']);
    });

    it('AC-ME-02 google_sub のみなら auth_providers=["google"]', async () => {
      prisma.user.findUnique.mockResolvedValue(
        userRow({ appleSub: null, googleSub: 'google-sub-1', email: null }),
      );
      const result = await service.getMe(USER_ID);
      expect(result.user.auth_providers).toEqual(['google']);
    });

    it('AC-ME-02 いずれも無ければ auth_providers=[]', async () => {
      prisma.user.findUnique.mockResolvedValue(
        userRow({ appleSub: null, googleSub: null, email: null }),
      );
      const result = await service.getMe(USER_ID);
      expect(result.user.auth_providers).toEqual([]);
    });

    it('plus の entitlement は identity_limit / share_limit が null', async () => {
      prisma.user.findUnique.mockResolvedValue(userRow());
      entitlements.get.mockResolvedValue(entitlementView({ plan: 'plus' }));
      entitlements.identityLimit.mockResolvedValue(null);
      entitlements.shareLimit.mockResolvedValue(null);

      const result = await service.getMe(USER_ID);
      expect(result.entitlement.plan).toBe('plus');
      expect(result.entitlement.identity_limit).toBeNull();
      expect(result.entitlement.share_limit).toBeNull();
    });
  });

  describe('updateMe', () => {
    it('AC-ME-05 送られたキーのみ Profile.update に渡し、未指定キーを null で潰さない', async () => {
      prisma.profile.update.mockResolvedValue(profileRow());
      prisma.user.findUnique.mockResolvedValue(userRow());

      await service.updateMe(USER_ID, { username: 'newname' });

      expect(prisma.profile.update).toHaveBeenCalledWith({
        where: { id: USER_ID },
        data: { username: 'newname' },
      });
    });

    it('AC-ME-05 複数キー指定時もそのキーのみが data に入る', async () => {
      prisma.profile.update.mockResolvedValue(profileRow());
      prisma.user.findUnique.mockResolvedValue(userRow());

      await service.updateMe(USER_ID, {
        theme_color: '#123456',
        onboarded_at: '2026-08-01T09:00:00.000Z',
      });

      expect(prisma.profile.update).toHaveBeenCalledWith({
        where: { id: USER_ID },
        data: {
          themeColor: '#123456',
          onboardedAt: new Date('2026-08-01T09:00:00.000Z'),
        },
      });
    });

    it('AC-ME-05 更新後は GET /v1/me と同形を返す', async () => {
      prisma.profile.update.mockResolvedValue(profileRow());
      prisma.user.findUnique.mockResolvedValue(userRow());

      const result = await service.updateMe(USER_ID, { username: 'newname' });

      expect(result.user.id).toBe(USER_ID);
      expect(result.profile).toBeDefined();
      expect(result.entitlement).toBeDefined();
    });

    it('AC-ME-05 空のボディでは Profile.update に空の data を渡す（何も変えない）', async () => {
      prisma.profile.update.mockResolvedValue(profileRow());
      prisma.user.findUnique.mockResolvedValue(userRow());

      await service.updateMe(USER_ID, {});

      expect(prisma.profile.update).toHaveBeenCalledWith({
        where: { id: USER_ID },
        data: {},
      });
    });
  });

  describe('findUserForDeletion', () => {
    it('BE-3 UseCase 用に users 行を認証ユーザーのスコープで読む', async () => {
      prisma.user.findUnique.mockResolvedValue({
        id: USER_ID,
        passwordHash: 'scrypt$...',
        appleSub: 'apple-sub-1',
      });

      const row = await service.findUserForDeletion(USER_ID);

      expect(prisma.user.findUnique).toHaveBeenCalledWith({
        where: { id: USER_ID },
        select: { id: true, passwordHash: true, appleSub: true },
      });
      expect(row).toEqual({
        id: USER_ID,
        passwordHash: 'scrypt$...',
        appleSub: 'apple-sub-1',
      });
    });

    it('存在しなければ null を返す（例外にしない）', async () => {
      prisma.user.findUnique.mockResolvedValue(null);
      await expect(service.findUserForDeletion(USER_ID)).resolves.toBeNull();
    });
  });

  describe('deleteAccount', () => {
    it('AC-AD-05 applications を identities より先に削除する（Restrict 回避）', async () => {
      await service.deleteAccount(USER_ID);

      const models = txCalls.map((call) => call.model);
      expect(models).toEqual(EXPECTED_DELETE_ORDER);
      expect(models.indexOf('application')).toBeLessThan(
        models.indexOf('identity'),
      );
      expect(models[models.length - 1]).toBe('user');
    });

    it('AC-AD-06 全ての削除が認証ユーザーのスコープで呼ばれる', async () => {
      await service.deleteAccount(USER_ID);

      expect(txCalls).toHaveLength(EXPECTED_DELETE_ORDER.length);
      for (const call of txCalls) {
        expect(Object.keys(call.where)).toHaveLength(1);
        expect(Object.values(call.where)).toEqual([USER_ID]);
      }
    });

    it('AC-AD-06 ownerId / userId / id の使い分けが schema と一致する', async () => {
      await service.deleteAccount(USER_ID);

      const whereKeyOf = (model: string) =>
        Object.keys(txCalls.find((c) => c.model === model)!.where)[0];

      for (const model of [
        'applicationCompanion',
        'application',
        'membership',
        'identity',
        'event',
        'tour',
        'shareLink',
      ]) {
        expect(whereKeyOf(model)).toBe('ownerId');
      }
      for (const model of [
        'deviceToken',
        'refreshToken',
        'passwordResetCode',
        'entitlement',
      ]) {
        expect(whereKeyOf(model)).toBe('userId');
      }
      expect(whereKeyOf('profile')).toBe('id');
      expect(whereKeyOf('user')).toBe('id');
    });

    it('E-12 deletedAt の条件を付けない（ソフトデリート済みも物理削除する）', async () => {
      await service.deleteAccount(USER_ID);

      for (const call of txCalls) {
        expect(call.where).not.toHaveProperty('deletedAt');
      }
    });

    it('AC-AD-10 削除は単一の $transaction 内で行われる（timeout 指定つき）', async () => {
      await service.deleteAccount(USER_ID);

      expect(prisma.$transaction).toHaveBeenCalledTimes(1);
      const [callback, options] = prisma.$transaction.mock.calls[0] as [
        unknown,
        unknown,
      ];
      expect(typeof callback).toBe('function');
      expect(options).toEqual({ maxWait: 5_000, timeout: 15_000 });
    });

    it('AC-AD-07 P2025 を NOT_FOUND 404 に写す（BE-6）', async () => {
      prisma.$transaction.mockImplementation(
        (callback: (tx: unknown) => Promise<unknown>) =>
          callback(buildTx(txCalls, { user: prismaP2025() })),
      );

      const error = await service
        .deleteAccount(USER_ID)
        .catch((e: unknown) => e);

      expect(error).toBeInstanceOf(AppError);
      expect((error as AppError).code).toBe(ErrorCode.NOT_FOUND);
      expect((error as AppError).getStatus()).toBe(404);
      expect((error as AppError).message).toBe('user not found');
    });

    it('P2025 以外の Prisma エラーは握りつぶさずそのまま投げる（P2003 を 404 にしない）', async () => {
      const fkViolation = new Prisma.PrismaClientKnownRequestError(
        'Foreign key constraint failed',
        { code: 'P2003', clientVersion: '6.19.0' },
      );
      prisma.$transaction.mockImplementation(
        (callback: (tx: unknown) => Promise<unknown>) =>
          callback(buildTx(txCalls, { identity: fkViolation })),
      );

      await expect(service.deleteAccount(USER_ID)).rejects.toBe(fkViolation);
    });
  });

  it('AC-ME-06 entitlement への書き込みメソッドが me モジュールに存在しない', () => {
    const methods = Object.getOwnPropertyNames(
      Object.getPrototypeOf(service),
    ).filter((m) => m !== 'constructor');
    expect(methods.sort()).toEqual([
      'deleteAccount',
      'findUserForDeletion',
      'getMe',
      'updateMe',
    ]);
  });
});
