import { ErrorCode } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import { ApplicationsService } from './applications.service';
import { ListApplicationsQueryDto } from './dto/list-applications-query.dto';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const APP_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const EVENT_ID = '018f3c2a-eeee-7c90-9d2a-000000000001';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';
const NOW = new Date('2026-07-31T12:05:00.000Z');

function applicationRow(overrides: Record<string, unknown> = {}) {
  return {
    id: APP_ID,
    ownerId: USER_ID,
    eventId: EVENT_ID,
    repIdentityId: IDENTITY_ID,
    repMembershipId: null,
    roundName: 'FC1次',
    appliedOn: new Date('2026-07-01T00:00:00.000Z'),
    resultOn: null,
    status: 'applied',
    seatRaw: null,
    ticketCount: 2,
    priceYen: 16000,
    note: null,
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
    event: { tourId: TOUR_ID },
    companions: [],
    ...overrides,
  };
}

function query(overrides: Partial<ListApplicationsQueryDto> = {}) {
  return { limit: 50, ...overrides } as ListApplicationsQueryDto;
}

describe('ApplicationsService', () => {
  let prisma: {
    application: {
      findMany: jest.Mock;
      findFirst: jest.Mock;
      findUnique: jest.Mock;
      update: jest.Mock;
    };
    applicationCompanion: { updateMany: jest.Mock };
    $transaction: jest.Mock;
  };
  let service: ApplicationsService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      application: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        findUnique: jest.fn(),
        update: jest.fn(),
      },
      applicationCompanion: { updateMany: jest.fn() },
      $transaction: jest.fn((cb: (client: unknown) => unknown) => cb(prisma)),
    };
    service = new ApplicationsService(prisma as unknown as PrismaService);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('list', () => {
    it('AC-APP-17 一覧クエリには必ず ownerId 条件が付く (BE-4)', async () => {
      prisma.application.findMany.mockResolvedValue([]);

      await service.list(USER_ID, query());

      const args = prisma.application.findMany.mock.calls[0][0] as {
        where: Record<string, unknown>;
        orderBy: unknown;
        take: number;
      };
      expect(args.where).toMatchObject({ ownerId: USER_ID, deletedAt: null });
      expect(args.orderBy).toEqual([{ updatedAt: 'asc' }, { id: 'asc' }]);
      expect(args.take).toBe(51);
    });

    it('AC-APP-16 has_more と next_cursor（返却最終要素の updated_at|id 複合）', async () => {
      const t1 = new Date('2026-07-31T12:00:00.000Z');
      const t2 = new Date('2026-07-31T12:01:00.000Z');
      const t3 = new Date('2026-07-31T12:02:00.000Z');
      prisma.application.findMany.mockResolvedValue([
        applicationRow({ id: '018f3c2a-cccc-7c90-9d2a-000000000001', updatedAt: t1 }),
        applicationRow({ id: '018f3c2a-cccc-7c90-9d2a-000000000002', updatedAt: t2 }),
        applicationRow({ id: '018f3c2a-cccc-7c90-9d2a-000000000003', updatedAt: t3 }),
      ]);

      const result = await service.list(USER_ID, query({ limit: 2 }));

      expect(result.items).toHaveLength(2);
      expect(result.has_more).toBe(true);
      expect(result.next_cursor).toBe(
        `${t2.toISOString()}|018f3c2a-cccc-7c90-9d2a-000000000002`,
      );
    });

    it('AC-APP-16 limit 以下なら has_more=false・next_cursor は最終要素の複合カーソル', async () => {
      const t1 = new Date('2026-07-31T12:00:00.000Z');
      prisma.application.findMany.mockResolvedValue([
        applicationRow({ updatedAt: t1 }),
      ]);

      const result = await service.list(USER_ID, query({ limit: 2 }));

      expect(result.has_more).toBe(false);
      expect(result.next_cursor).toBe(`${t1.toISOString()}|${APP_ID}`);
    });

    it('AC-APP-16 0 件なら next_cursor は null', async () => {
      prisma.application.findMany.mockResolvedValue([]);

      const result = await service.list(USER_ID, query());

      expect(result).toEqual({ items: [], next_cursor: null, has_more: false });
    });

    it('AC-APP-16 cursor は (updated_at, id) の複合条件になる', async () => {
      prisma.application.findMany.mockResolvedValue([]);

      await service.list(
        USER_ID,
        query({ cursor: `2026-07-31T12:05:00.000Z|${APP_ID}` }),
      );

      const args = prisma.application.findMany.mock.calls[0][0] as {
        where: { OR?: unknown; updatedAt?: unknown };
      };
      expect(args.where.updatedAt).toBeUndefined();
      expect(args.where.OR).toEqual([
        { updatedAt: { gt: new Date('2026-07-31T12:05:00.000Z') } },
        {
          updatedAt: new Date('2026-07-31T12:05:00.000Z'),
          id: { gt: APP_ID },
        },
      ]);
    });

    it('AC-APP-16 updated_at 同値の行を次ページで取りこぼさない（複合カーソルの往復）', async () => {
      const t = new Date('2026-07-31T12:00:00.000Z');
      const id1 = '018f3c2a-cccc-7c90-9d2a-000000000001';
      const id2 = '018f3c2a-cccc-7c90-9d2a-000000000002';
      prisma.application.findMany.mockResolvedValue([
        applicationRow({ id: id1, updatedAt: t }),
        applicationRow({ id: id2, updatedAt: t }),
      ]);

      const first = await service.list(USER_ID, query({ limit: 1 }));
      expect(first.next_cursor).toBe(`${t.toISOString()}|${id1}`);

      prisma.application.findMany.mockResolvedValue([]);
      await service.list(USER_ID, query({ cursor: first.next_cursor! }));

      const args = prisma.application.findMany.mock.calls[1][0] as {
        where: { OR?: unknown };
      };
      // 同一 updated_at の id2 が次ページの候補として残る
      expect(args.where.OR).toEqual([
        { updatedAt: { gt: t } },
        { updatedAt: t, id: { gt: id1 } },
      ]);
    });

    it('AC-APP-16 壊れた cursor は VALIDATION_ERROR 400', async () => {
      for (const bad of [
        'yesterday',
        'not-a-date|x',
        `|${APP_ID}`,
        'x|',
        // 中-6: id 部分が UUID の形をしていない場合も 400（500 にしない）
        '2026-07-31T12:05:00.000Z|not-a-uuid',
      ]) {
        await expect(
          service.list(USER_ID, query({ cursor: bad })),
        ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
      }
      expect(prisma.application.findMany).not.toHaveBeenCalled();
    });

    it('status / tour_id / event_id / rep_identity_id で絞り込む', async () => {
      prisma.application.findMany.mockResolvedValue([]);

      await service.list(
        USER_ID,
        query({
          status: ['applied', 'won'],
          tour_id: TOUR_ID,
          event_id: EVENT_ID,
          rep_identity_id: IDENTITY_ID,
        }),
      );

      const args = prisma.application.findMany.mock.calls[0][0] as {
        where: Record<string, unknown>;
      };
      expect(args.where).toMatchObject({
        ownerId: USER_ID,
        status: { in: ['applied', 'won'] },
        eventId: EVENT_ID,
        repIdentityId: IDENTITY_ID,
        event: { tourId: TOUR_ID },
      });
    });

    it('include_deleted=true なら deletedAt で絞らない', async () => {
      prisma.application.findMany.mockResolvedValue([]);

      await service.list(USER_ID, query({ include_deleted: true }));

      const args = prisma.application.findMany.mock.calls[0][0] as {
        where: Record<string, unknown>;
      };
      expect(args.where.deletedAt).toBeUndefined();
    });

    it('レスポンス要素は契約形（tour_id は event から導出）', async () => {
      prisma.application.findMany.mockResolvedValue([
        applicationRow({
          companions: [
            {
              id: '018f3c2a-ffff-7c90-9d2a-000000000001',
              identityId: null,
              displayName: '妹',
              position: 0,
            },
          ],
        }),
      ]);

      const result = await service.list(USER_ID, query());

      expect(result.items[0]).toEqual({
        id: APP_ID,
        tour_id: TOUR_ID,
        event_id: EVENT_ID,
        rep_identity_id: IDENTITY_ID,
        rep_membership_id: null,
        round_name: 'FC1次',
        applied_on: '2026-07-01',
        result_on: null,
        status: 'applied',
        seat_raw: null,
        ticket_count: 2,
        price_yen: 16000,
        note: null,
        companions: [
          {
            id: '018f3c2a-ffff-7c90-9d2a-000000000001',
            identity_id: null,
            display_name: '妹',
            position: 0,
          },
        ],
        created_at: NOW.toISOString(),
        updated_at: NOW.toISOString(),
        deleted_at: null,
      });
    });
  });

  describe('get', () => {
    it('AC-APP-17 他人の application 単体取得は NOT_FOUND 404 (BE-4)', async () => {
      prisma.application.findFirst.mockResolvedValue(null);

      await expect(service.get(OTHER_USER_ID, APP_ID)).rejects.toMatchObject({
        code: ErrorCode.NOT_FOUND,
      });
      const args = prisma.application.findFirst.mock.calls[0][0] as {
        where: Record<string, unknown>;
      };
      expect(args.where).toMatchObject({
        id: APP_ID,
        ownerId: OTHER_USER_ID,
      });
    });
  });

  describe('remove', () => {
    it('application と配下 companions をソフトデリートする', async () => {
      prisma.application.findFirst.mockResolvedValue(applicationRow());

      await service.remove(USER_ID, APP_ID);

      expect(prisma.application.update).toHaveBeenCalledWith({
        where: { id: APP_ID },
        data: { deletedAt: NOW },
      });
      expect(prisma.applicationCompanion.updateMany).toHaveBeenCalledWith({
        where: { applicationId: APP_ID, deletedAt: null },
        data: { deletedAt: NOW },
      });
    });

    it('2 回目の DELETE も冪等（書き込まない）', async () => {
      prisma.application.findFirst.mockResolvedValue(
        applicationRow({ deletedAt: NOW }),
      );

      await expect(service.remove(USER_ID, APP_ID)).resolves.toBeUndefined();
      expect(prisma.application.update).not.toHaveBeenCalled();
      expect(prisma.applicationCompanion.updateMany).not.toHaveBeenCalled();
    });

    it('他人の application の DELETE は NOT_FOUND 404', async () => {
      prisma.application.findFirst.mockResolvedValue(null);

      await expect(
        service.remove(OTHER_USER_ID, APP_ID),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    });
  });

  describe('assertMembershipOwned', () => {
    it('自分の membership かつ identity 一致なら通る', async () => {
      const prismaWithMembership = prisma as unknown as {
        membership: { findFirst: jest.Mock };
      };
      prismaWithMembership.membership = {
        findFirst: jest.fn().mockResolvedValue({ id: 'x' }),
      };

      await expect(
        service.assertMembershipOwned(
          USER_ID,
          '018f3c2a-bbbb-7c90-9d2a-000000000001',
          IDENTITY_ID,
        ),
      ).resolves.toBeDefined();
    });

    it('見つからなければ NOT_FOUND 404', async () => {
      const prismaWithMembership = prisma as unknown as {
        membership: { findFirst: jest.Mock };
      };
      prismaWithMembership.membership = {
        findFirst: jest.fn().mockResolvedValue(null),
      };

      await expect(
        service.assertMembershipOwned(
          USER_ID,
          '018f3c2a-bbbb-7c90-9d2a-000000000001',
          IDENTITY_ID,
        ),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    });
  });
});
