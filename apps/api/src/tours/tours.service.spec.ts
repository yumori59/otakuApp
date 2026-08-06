import { ErrorCode } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import { ToursService } from './tours.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-01T00:00:00.000Z');

function tourRow(overrides: Record<string, unknown> = {}) {
  return {
    id: TOUR_ID,
    ownerId: USER_ID,
    name: 'STELLARIS LIVE TOUR 2026',
    artistNameRaw: 'STELLARIS',
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
    ...overrides,
  };
}

describe('ToursService', () => {
  let prisma: {
    tour: {
      findMany: jest.Mock;
      findFirst: jest.Mock;
      findUnique: jest.Mock;
      create: jest.Mock;
      update: jest.Mock;
    };
    event: { updateMany: jest.Mock };
    application: { updateMany: jest.Mock };
  };
  let service: ToursService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      tour: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
      event: { updateMany: jest.fn() },
      application: { updateMany: jest.fn() },
    };
    service = new ToursService(prisma as unknown as PrismaService);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('list / get', () => {
    it('list は ownerId スコープ + 未削除のみ (BE-4)', async () => {
      prisma.tour.findMany.mockResolvedValue([tourRow()]);

      const result = await service.list(USER_ID);

      expect(prisma.tour.findMany).toHaveBeenCalledWith({
        where: { ownerId: USER_ID, deletedAt: null },
        orderBy: [{ name: 'asc' }],
      });
      expect(result).toEqual([
        {
          id: TOUR_ID,
          name: 'STELLARIS LIVE TOUR 2026',
          artist_name_raw: 'STELLARIS',
          created_at: NOW.toISOString(),
          updated_at: NOW.toISOString(),
          deleted_at: null,
        },
      ]);
    });

    it('他人の tour への get は NOT_FOUND 404 (BE-4)', async () => {
      prisma.tour.findFirst.mockResolvedValue(null);

      await expect(service.get(OTHER_USER_ID, TOUR_ID)).rejects.toMatchObject({
        code: ErrorCode.NOT_FOUND,
      });
    });
  });

  describe('update', () => {
    it('name / artist_name_raw のみ更新する', async () => {
      prisma.tour.findFirst.mockResolvedValue(tourRow());
      prisma.tour.findUnique.mockResolvedValue(null);
      prisma.tour.update.mockResolvedValue(tourRow({ name: 'NEW' }));

      await service.update(USER_ID, TOUR_ID, {
        name: 'NEW',
        artist_name_raw: 'ARTIST',
      });

      expect(prisma.tour.update).toHaveBeenCalledWith({
        where: { id: TOUR_ID },
        data: { name: 'NEW', artistNameRaw: 'ARTIST' },
      });
    });

    it('name 変更で同名 tour と衝突したら CONFLICT 409', async () => {
      prisma.tour.findFirst.mockResolvedValue(tourRow());
      prisma.tour.findUnique.mockResolvedValue(
        tourRow({ id: '018f3c2a-dddd-7c90-9d2a-000000000002', name: 'NEW' }),
      );

      await expect(
        service.update(USER_ID, TOUR_ID, { name: 'NEW' }),
      ).rejects.toMatchObject({ code: ErrorCode.CONFLICT });
      expect(prisma.tour.update).not.toHaveBeenCalled();
    });

    it('name が現在値と同じなら衝突チェックをしない', async () => {
      prisma.tour.findFirst.mockResolvedValue(tourRow());
      prisma.tour.update.mockResolvedValue(tourRow());

      await service.update(USER_ID, TOUR_ID, {
        name: 'STELLARIS LIVE TOUR 2026',
      });

      expect(prisma.tour.findUnique).not.toHaveBeenCalled();
      expect(prisma.tour.update).toHaveBeenCalled();
    });
  });

  describe('remove', () => {
    it('AC-APP-21 tour の DELETE で配下 event / application は削除されない (C4)', async () => {
      prisma.tour.findFirst.mockResolvedValue(tourRow());
      prisma.tour.update.mockResolvedValue(tourRow({ deletedAt: NOW }));

      await service.remove(USER_ID, TOUR_ID);

      expect(prisma.tour.update).toHaveBeenCalledWith({
        where: { id: TOUR_ID },
        data: { deletedAt: NOW },
      });
      expect(prisma.event.updateMany).not.toHaveBeenCalled();
      expect(prisma.application.updateMany).not.toHaveBeenCalled();
    });

    it('2 回目の DELETE も冪等（update を呼ばない）', async () => {
      prisma.tour.findFirst.mockResolvedValue(tourRow({ deletedAt: NOW }));

      await expect(service.remove(USER_ID, TOUR_ID)).resolves.toBeUndefined();
      expect(prisma.tour.update).not.toHaveBeenCalled();
    });

    it('他人の tour の DELETE は NOT_FOUND 404', async () => {
      prisma.tour.findFirst.mockResolvedValue(null);

      await expect(
        service.remove(OTHER_USER_ID, TOUR_ID),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    });
  });

  describe('findOrCreateByName', () => {
    it('AC-APP-01 同名 tour があれば新規作成せず再利用する', async () => {
      prisma.tour.findUnique.mockResolvedValue(tourRow());

      const result = await service.findOrCreateByName(USER_ID, {
        name: 'STELLARIS LIVE TOUR 2026',
      });

      expect(prisma.tour.findUnique).toHaveBeenCalledWith({
        where: {
          ownerId_name: { ownerId: USER_ID, name: 'STELLARIS LIVE TOUR 2026' },
        },
      });
      expect(prisma.tour.create).not.toHaveBeenCalled();
      expect(prisma.tour.update).not.toHaveBeenCalled();
      expect(result.id).toBe(TOUR_ID);
    });

    it('AC-APP-02 ソフトデリート済み同名 tour は deletedAt:null で復活して再利用する', async () => {
      prisma.tour.findUnique.mockResolvedValue(tourRow({ deletedAt: NOW }));
      prisma.tour.update.mockResolvedValue(tourRow());

      await service.findOrCreateByName(USER_ID, {
        name: 'STELLARIS LIVE TOUR 2026',
        artist_name_raw: 'NEW ARTIST',
      });

      expect(prisma.tour.update).toHaveBeenCalledWith({
        where: { id: TOUR_ID },
        data: { deletedAt: null, artistNameRaw: 'NEW ARTIST' },
      });
      expect(prisma.tour.create).not.toHaveBeenCalled();
    });

    it('見つからなければ dto の id で作成し ownerId はサーバーが設定する (BE-4)', async () => {
      prisma.tour.findUnique.mockResolvedValue(null);
      prisma.tour.create.mockResolvedValue(tourRow());

      await service.findOrCreateByName(USER_ID, {
        id: TOUR_ID,
        name: 'STELLARIS LIVE TOUR 2026',
        artist_name_raw: 'STELLARIS',
      });

      expect(prisma.tour.create).toHaveBeenCalledWith({
        data: {
          id: TOUR_ID,
          ownerId: USER_ID,
          name: 'STELLARIS LIVE TOUR 2026',
          artistNameRaw: 'STELLARIS',
        },
      });
    });

    it('id 省略時はサーバーが UUID を発行する (BE-1)', async () => {
      prisma.tour.findUnique.mockResolvedValue(null);
      prisma.tour.create.mockResolvedValue(tourRow());

      await service.findOrCreateByName(USER_ID, { name: 'NO ID TOUR' });

      const arg = prisma.tour.create.mock.calls[0][0] as {
        data: { id: string };
      };
      expect(arg.data.id).toMatch(
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i,
      );
    });

    it('tx を渡すと tx クライアント側で読み書きする', async () => {
      const tx = {
        tour: {
          findUnique: jest.fn().mockResolvedValue(null),
          create: jest.fn().mockResolvedValue(tourRow()),
          update: jest.fn(),
        },
      };

      await service.findOrCreateByName(
        USER_ID,
        { name: 'TX TOUR' },
        tx as never,
      );

      expect(tx.tour.create).toHaveBeenCalled();
      expect(prisma.tour.create).not.toHaveBeenCalled();
    });
  });

  describe('assertOwned', () => {
    it('他人 / 削除済み tour は NOT_FOUND', async () => {
      prisma.tour.findFirst.mockResolvedValue(null);

      await expect(
        service.assertOwned(USER_ID, TOUR_ID),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
      expect(prisma.tour.findFirst).toHaveBeenCalledWith({
        where: { id: TOUR_ID, ownerId: USER_ID, deletedAt: null },
      });
    });
  });
});
