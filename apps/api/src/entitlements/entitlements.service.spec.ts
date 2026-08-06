import { PrismaService } from '../prisma/prisma.service';
import { EntitlementsService } from './entitlements.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const NOW = new Date('2026-08-01T00:00:00.000Z');

function row(overrides: Record<string, unknown> = {}) {
  return {
    userId: USER_ID,
    plan: 'free',
    productId: null,
    store: null,
    expiresAt: null,
    inGracePeriod: false,
    revenuecatCustomerId: null,
    bonusIdentitySlots: 0,
    bonusExpiresAt: null,
    updatedAt: NOW,
    ...overrides,
  };
}

describe('EntitlementsService', () => {
  let prisma: { entitlement: { findUnique: jest.Mock } };
  let service: EntitlementsService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = { entitlement: { findUnique: jest.fn() } };
    service = new EntitlementsService(prisma as unknown as PrismaService);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('get', () => {
    it('AC-CORE-07 entitlement 行が無ければ free / bonus 0 の既定を返す', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(null);

      await expect(service.get(USER_ID)).resolves.toEqual({
        plan: 'free',
        expiresAt: null,
        inGracePeriod: false,
        bonusIdentitySlots: 0,
        bonusExpiresAt: null,
      });
      expect(prisma.entitlement.findUnique).toHaveBeenCalledWith({
        where: { userId: USER_ID },
      });
    });

    it('AC-CORE-07 行があればその値を返す', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({ plan: 'plus', bonusIdentitySlots: 2 }),
      );

      await expect(service.get(USER_ID)).resolves.toEqual({
        plan: 'plus',
        expiresAt: null,
        inGracePeriod: false,
        bonusIdentitySlots: 2,
        bonusExpiresAt: null,
      });
    });
  });

  describe('identityLimit', () => {
    it('AC-CORE-07 free は 3', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(row());
      await expect(service.identityLimit(USER_ID)).resolves.toBe(3);
    });

    it('AC-CORE-07 entitlement 行なしは 3', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(null);
      await expect(service.identityLimit(USER_ID)).resolves.toBe(3);
    });

    it('AC-CORE-07 free + 有効な bonus 2 枠は 5', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({
          bonusIdentitySlots: 2,
          bonusExpiresAt: new Date('2026-09-01T00:00:00.000Z'),
        }),
      );
      await expect(service.identityLimit(USER_ID)).resolves.toBe(5);
    });

    it('AC-CORE-07 free + 期限切れ bonus は 3', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({
          bonusIdentitySlots: 2,
          bonusExpiresAt: new Date('2026-07-31T23:59:59.000Z'),
        }),
      );
      await expect(service.identityLimit(USER_ID)).resolves.toBe(3);
    });

    it('AC-CORE-07 bonus 期限ちょうどは無効（3）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({ bonusIdentitySlots: 2, bonusExpiresAt: NOW }),
      );
      await expect(service.identityLimit(USER_ID)).resolves.toBe(3);
    });

    it('AC-CORE-07 plus は null（無制限）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(row({ plan: 'plus' }));
      await expect(service.identityLimit(USER_ID)).resolves.toBeNull();
    });

    it('AC-CORE-07 猶予期間中は null（無制限）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({
          plan: 'plus',
          inGracePeriod: true,
          expiresAt: new Date('2026-07-01T00:00:00.000Z'),
        }),
      );
      await expect(service.identityLimit(USER_ID)).resolves.toBeNull();
    });

    it('AC-CORE-07 free + in_grace_period=true は上限 3（plus 以外に無制限を与えない）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({ plan: 'free', inGracePeriod: true }),
      );
      await expect(service.identityLimit(USER_ID)).resolves.toBe(3);
    });

    it('AC-CORE-07 free + in_grace_period=true でも bonus 枠は加算される（5）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({
          plan: 'free',
          inGracePeriod: true,
          bonusIdentitySlots: 2,
          bonusExpiresAt: new Date('2026-09-01T00:00:00.000Z'),
        }),
      );
      await expect(service.identityLimit(USER_ID)).resolves.toBe(5);
    });

    it('AC-CORE-07 期限切れ plus（猶予なし）は free 相当の 3', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({
          plan: 'plus',
          expiresAt: new Date('2026-07-01T00:00:00.000Z'),
          inGracePeriod: false,
        }),
      );
      await expect(service.identityLimit(USER_ID)).resolves.toBe(3);
    });
  });

  describe('shareLimit', () => {
    it('AC-CORE-08 free は 1', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(row());
      await expect(service.shareLimit(USER_ID)).resolves.toBe(1);
    });

    it('AC-CORE-08 entitlement 行なしは 1', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(null);
      await expect(service.shareLimit(USER_ID)).resolves.toBe(1);
    });

    it('AC-CORE-08 plus は null（無制限）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(row({ plan: 'plus' }));
      await expect(service.shareLimit(USER_ID)).resolves.toBeNull();
    });

    it('AC-CORE-08 plus + 猶予期間中は null（無制限）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({
          plan: 'plus',
          inGracePeriod: true,
          expiresAt: new Date('2026-07-01T00:00:00.000Z'),
        }),
      );
      await expect(service.shareLimit(USER_ID)).resolves.toBeNull();
    });

    it('AC-CORE-08 free + in_grace_period=true は上限 1（plus 以外に無制限を与えない）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({ plan: 'free', inGracePeriod: true }),
      );
      await expect(service.shareLimit(USER_ID)).resolves.toBe(1);
    });
  });

  describe('shareWriteEventLimit', () => {
    it('AC-SW-03(準備) free は 3', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(row());
      await expect(service.shareWriteEventLimit(USER_ID)).resolves.toBe(3);
    });

    it('AC-SW-03(準備) entitlement 行なしは 3', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(null);
      await expect(service.shareWriteEventLimit(USER_ID)).resolves.toBe(3);
    });

    it('AC-SW-03(準備) free + bonusIdentitySlots があっても 3（bonus は名義枠専用で別軸）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({
          bonusIdentitySlots: 2,
          bonusExpiresAt: new Date('2026-09-01T00:00:00.000Z'),
        }),
      );
      await expect(service.shareWriteEventLimit(USER_ID)).resolves.toBe(3);
    });

    it('AC-SW-03(準備) plus は null（無制限）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(row({ plan: 'plus' }));
      await expect(service.shareWriteEventLimit(USER_ID)).resolves.toBeNull();
    });

    it('AC-SW-03(準備) plus + 猶予期間中は null（無制限）', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({
          plan: 'plus',
          inGracePeriod: true,
          expiresAt: new Date('2026-07-01T00:00:00.000Z'),
        }),
      );
      await expect(service.shareWriteEventLimit(USER_ID)).resolves.toBeNull();
    });

    it('AC-SW-03(準備) 期限切れ plus（猶予なし）は free 相当の 3', async () => {
      prisma.entitlement.findUnique.mockResolvedValue(
        row({
          plan: 'plus',
          expiresAt: new Date('2026-07-01T00:00:00.000Z'),
          inGracePeriod: false,
        }),
      );
      await expect(service.shareWriteEventLimit(USER_ID)).resolves.toBe(3);
    });
  });

  it('ADR-002 書き込みメソッドを公開しない', () => {
    const methods = Object.getOwnPropertyNames(
      Object.getPrototypeOf(service),
    ).filter((m) => m !== 'constructor');
    expect(methods.sort()).toEqual([
      'get',
      'identityLimit',
      'shareLimit',
      'shareWriteEventLimit',
    ]);
  });
});
