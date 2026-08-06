import { PrismaService } from '../prisma/prisma.service';
import { EntitlementsService } from '../entitlements/entitlements.service';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { IdentitiesService } from './identities.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-01T00:00:00.000Z');

function identityRow(overrides: Record<string, unknown> = {}) {
  return {
    id: IDENTITY_ID,
    ownerId: USER_ID,
    displayName: '自分',
    relation: 'self',
    color: '#0017C1',
    joinedOn: null,
    note: null,
    historyVisible: false,
    sortOrder: 0,
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
    ...overrides,
  };
}

describe('IdentitiesService', () => {
  let prisma: {
    identity: {
      findMany: jest.Mock;
      findFirst: jest.Mock;
      findUnique: jest.Mock;
      count: jest.Mock;
      create: jest.Mock;
      update: jest.Mock;
    };
  };
  let entitlements: { identityLimit: jest.Mock };
  let service: IdentitiesService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      identity: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        findUnique: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
    };
    entitlements = { identityLimit: jest.fn().mockResolvedValue(3) };
    service = new IdentitiesService(
      prisma as unknown as PrismaService,
      entitlements as unknown as EntitlementsService,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('create', () => {
    it('AC-IDT-01 owner_id はリクエストではなく userId から設定される', async () => {
      prisma.identity.findUnique.mockResolvedValue(null);
      prisma.identity.count.mockResolvedValue(0);
      prisma.identity.create.mockResolvedValue(identityRow());

      await service.create(USER_ID, {
        id: IDENTITY_ID,
        display_name: '自分',
      });

      expect(prisma.identity.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({ ownerId: USER_ID }),
        }),
      );
    });

    it('AC-IDT-02 free で 3 件保持時の 4 件目は PLAN_LIMIT_IDENTITY 403', async () => {
      prisma.identity.findUnique.mockResolvedValue(null);
      entitlements.identityLimit.mockResolvedValue(3);
      prisma.identity.count.mockResolvedValue(3);

      await expect(
        service.create(USER_ID, { id: IDENTITY_ID, display_name: '4人目' }),
      ).rejects.toMatchObject({
        code: ErrorCode.PLAN_LIMIT_IDENTITY,
        details: { limit: 3, current: 3 },
      });
      expect(prisma.identity.create).not.toHaveBeenCalled();
    });

    it('AC-IDT-03 count は deletedAt:null で絞る（ソフトデリート済みは上限にカウントしない）', async () => {
      prisma.identity.findUnique.mockResolvedValue(null);
      entitlements.identityLimit.mockResolvedValue(3);
      prisma.identity.count.mockResolvedValue(2);
      prisma.identity.create.mockResolvedValue(identityRow());

      await service.create(USER_ID, { id: IDENTITY_ID, display_name: '3人目' });

      expect(prisma.identity.count).toHaveBeenCalledWith({
        where: { ownerId: USER_ID, deletedAt: null },
      });
      expect(prisma.identity.create).toHaveBeenCalled();
    });

    it('AC-IDT-04 有効な bonus 枠があると上限が拡張される', async () => {
      prisma.identity.findUnique.mockResolvedValue(null);
      entitlements.identityLimit.mockResolvedValue(5);
      prisma.identity.count.mockResolvedValue(4);
      prisma.identity.create.mockResolvedValue(identityRow());

      await service.create(USER_ID, { id: IDENTITY_ID, display_name: '5人目' });

      expect(prisma.identity.create).toHaveBeenCalled();
    });

    it('AC-IDT-05 plus (limit=null) は件数チェックせず作成できる', async () => {
      prisma.identity.findUnique.mockResolvedValue(null);
      entitlements.identityLimit.mockResolvedValue(null);
      prisma.identity.create.mockResolvedValue(identityRow());

      await service.create(USER_ID, { id: IDENTITY_ID, display_name: '無制限' });

      expect(prisma.identity.count).not.toHaveBeenCalled();
      expect(prisma.identity.create).toHaveBeenCalled();
    });

    it('AC-IDT-09 既存 id への再 POST は CONFLICT 409', async () => {
      prisma.identity.findUnique.mockResolvedValue(identityRow());

      await expect(
        service.create(USER_ID, { id: IDENTITY_ID, display_name: '重複' }),
      ).rejects.toMatchObject({ code: ErrorCode.CONFLICT });
      expect(prisma.identity.create).not.toHaveBeenCalled();
    });

    it('AC-IDT-11 history_visible 省略時の既定は false', async () => {
      prisma.identity.findUnique.mockResolvedValue(null);
      prisma.identity.count.mockResolvedValue(0);
      prisma.identity.create.mockResolvedValue(identityRow());

      await service.create(USER_ID, { id: IDENTITY_ID, display_name: '既定確認' });

      expect(prisma.identity.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({
            historyVisible: false,
            relation: 'other',
            color: '#0017C1',
            sortOrder: 0,
          }),
        }),
      );
    });
  });

  describe('assertOwned', () => {
    it('AC-IDT-12 所有者一致・未削除なら行を返す', async () => {
      const row = identityRow();
      prisma.identity.findFirst.mockResolvedValue(row);

      await expect(service.assertOwned(USER_ID, IDENTITY_ID)).resolves.toEqual(
        row,
      );
      expect(prisma.identity.findFirst).toHaveBeenCalledWith({
        where: { id: IDENTITY_ID, ownerId: USER_ID, deletedAt: null },
      });
    });

    it('AC-IDT-12 他人 / 削除済み id では NOT_FOUND', async () => {
      prisma.identity.findFirst.mockResolvedValue(null);

      await expect(
        service.assertOwned(OTHER_USER_ID, IDENTITY_ID),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    });
  });

  describe('get / update / remove の ownerId スコープ', () => {
    it('AC-IDT-06 他人の identity への get は NOT_FOUND', async () => {
      prisma.identity.findFirst.mockResolvedValue(null);

      await expect(
        service.get(OTHER_USER_ID, IDENTITY_ID),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    });

    it('AC-IDT-06 他人の identity への update は NOT_FOUND', async () => {
      prisma.identity.findFirst.mockResolvedValue(null);

      await expect(
        service.update(OTHER_USER_ID, IDENTITY_ID, { display_name: 'x' }),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
      expect(prisma.identity.update).not.toHaveBeenCalled();
    });

    it('AC-IDT-06 他人の identity への remove は NOT_FOUND', async () => {
      prisma.identity.findFirst.mockResolvedValue(null);

      await expect(
        service.remove(OTHER_USER_ID, IDENTITY_ID),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
      expect(prisma.identity.update).not.toHaveBeenCalled();
    });
  });

  describe('remove', () => {
    it('AC-IDT-10 削除は行を消さず deletedAt を立てる', async () => {
      prisma.identity.findFirst.mockResolvedValue(identityRow());
      prisma.identity.update.mockResolvedValue(identityRow({ deletedAt: NOW }));

      await service.remove(USER_ID, IDENTITY_ID);

      expect(prisma.identity.update).toHaveBeenCalledWith({
        where: { id: IDENTITY_ID },
        data: { deletedAt: NOW },
      });
    });

    it('AC-IDT-10 2 回目の削除も冪等に成功する（update を呼ばない）', async () => {
      prisma.identity.findFirst.mockResolvedValue(identityRow({ deletedAt: NOW }));

      await expect(service.remove(USER_ID, IDENTITY_ID)).resolves.toBeUndefined();
      expect(prisma.identity.update).not.toHaveBeenCalled();
    });
  });

  describe('list', () => {
    it('include_deleted=false なら deletedAt:null で絞る', async () => {
      prisma.identity.findMany.mockResolvedValue([]);

      await service.list(USER_ID, false);

      expect(prisma.identity.findMany).toHaveBeenCalledWith({
        where: { ownerId: USER_ID, deletedAt: null },
        orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }],
      });
    });

    it('include_deleted=true なら deletedAt で絞らない', async () => {
      prisma.identity.findMany.mockResolvedValue([]);

      await service.list(USER_ID, true);

      expect(prisma.identity.findMany).toHaveBeenCalledWith({
        where: { ownerId: USER_ID },
        orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }],
      });
    });

    it('レスポンス要素は snake_case・ISO8601 に変換される', async () => {
      prisma.identity.findMany.mockResolvedValue([
        identityRow({ joinedOn: new Date('2024-04-01T00:00:00.000Z') }),
      ]);

      const result = await service.list(USER_ID, false);

      expect(result).toEqual([
        {
          id: IDENTITY_ID,
          display_name: '自分',
          relation: 'self',
          color: '#0017C1',
          joined_on: '2024-04-01',
          note: null,
          history_visible: false,
          sort_order: 0,
          created_at: NOW.toISOString(),
          updated_at: NOW.toISOString(),
          deleted_at: null,
        },
      ]);
    });
  });

  it('AppError は AppError.notFound と同じ形（instanceof 確認）', async () => {
    prisma.identity.findFirst.mockResolvedValue(null);
    try {
      await service.assertOwned(USER_ID, IDENTITY_ID);
      fail('should have thrown');
    } catch (e) {
      expect(e).toBeInstanceOf(AppError);
    }
  });

  describe('ensureWithinLimit', () => {
    it('既存 identity の更新は上限チェックをスキップする', async () => {
      prisma.identity.findFirst.mockResolvedValue(identityRow());

      await service.ensureWithinLimit(USER_ID, IDENTITY_ID);

      expect(entitlements.identityLimit).not.toHaveBeenCalled();
    });

    it('新規 identity で上限超過時 PLAN_LIMIT_IDENTITY', async () => {
      prisma.identity.findFirst.mockResolvedValue(null);
      entitlements.identityLimit.mockResolvedValue(3);
      prisma.identity.count.mockResolvedValue(3);

      await expect(
        service.ensureWithinLimit(USER_ID, IDENTITY_ID),
      ).rejects.toMatchObject({ code: ErrorCode.PLAN_LIMIT_IDENTITY });
    });
  });
});
