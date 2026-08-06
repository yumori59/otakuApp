import { ErrorCode } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import { EventsService } from './events.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const EVENT_ID = '018f3c2a-eeee-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-01T00:00:00.000Z');

function eventRow(overrides: Record<string, unknown> = {}) {
  return {
    id: EVENT_ID,
    ownerId: USER_ID,
    tourId: TOUR_ID,
    name: '大阪公演 Day1',
    venueNameRaw: '大阪城ホール',
    eventDate: new Date('2026-08-20T00:00:00.000Z'),
    startsAt: new Date('2026-08-20T11:00:00.000Z'),
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
    ...overrides,
  };
}

describe('EventsService', () => {
  let prisma: {
    event: {
      findMany: jest.Mock;
      findFirst: jest.Mock;
      findUnique: jest.Mock;
      create: jest.Mock;
      update: jest.Mock;
    };
    application: { updateMany: jest.Mock };
  };
  let service: EventsService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      event: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        findUnique: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
      application: { updateMany: jest.fn() },
    };
    service = new EventsService(prisma as unknown as PrismaService);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('list', () => {
    it('tour_id 指定時も必ず ownerId で絞る (BE-4)', async () => {
      prisma.event.findMany.mockResolvedValue([]);

      await service.list(USER_ID, TOUR_ID);

      expect(prisma.event.findMany).toHaveBeenCalledWith({
        where: { ownerId: USER_ID, deletedAt: null, tourId: TOUR_ID },
        orderBy: [{ eventDate: { sort: 'asc', nulls: 'last' } }, { name: 'asc' }],
      });
    });

    it('tour_id 未指定なら自分の全 event', async () => {
      prisma.event.findMany.mockResolvedValue([eventRow()]);

      const result = await service.list(USER_ID, undefined);

      expect(prisma.event.findMany).toHaveBeenCalledWith({
        where: { ownerId: USER_ID, deletedAt: null },
        orderBy: [{ eventDate: { sort: 'asc', nulls: 'last' } }, { name: 'asc' }],
      });
      expect(result).toEqual([
        {
          id: EVENT_ID,
          tour_id: TOUR_ID,
          name: '大阪公演 Day1',
          venue_name_raw: '大阪城ホール',
          event_date: '2026-08-20',
          starts_at: '2026-08-20T11:00:00.000Z',
          created_at: NOW.toISOString(),
          updated_at: NOW.toISOString(),
          deleted_at: null,
        },
      ]);
    });
  });

  describe('get / update / remove', () => {
    it('他人の event への get は NOT_FOUND 404 (BE-4)', async () => {
      prisma.event.findFirst.mockResolvedValue(null);

      await expect(service.get(OTHER_USER_ID, EVENT_ID)).rejects.toMatchObject({
        code: ErrorCode.NOT_FOUND,
      });
    });

    it('update は name / venue_name_raw / event_date / starts_at のみ反映する', async () => {
      prisma.event.findFirst.mockResolvedValue(eventRow());
      prisma.event.update.mockResolvedValue(eventRow());

      await service.update(USER_ID, EVENT_ID, {
        name: '大阪公演 Day2',
        venue_name_raw: null,
        event_date: '2026-08-21',
        starts_at: null,
      });

      expect(prisma.event.update).toHaveBeenCalledWith({
        where: { id: EVENT_ID },
        data: {
          name: '大阪公演 Day2',
          venueNameRaw: null,
          eventDate: new Date('2026-08-21T00:00:00.000Z'),
          startsAt: null,
        },
      });
    });

    it('remove はソフトデリートで配下 application を連鎖させない (C4)', async () => {
      prisma.event.findFirst.mockResolvedValue(eventRow());
      prisma.event.update.mockResolvedValue(eventRow({ deletedAt: NOW }));

      await service.remove(USER_ID, EVENT_ID);

      expect(prisma.event.update).toHaveBeenCalledWith({
        where: { id: EVENT_ID },
        data: { deletedAt: NOW },
      });
      expect(prisma.application.updateMany).not.toHaveBeenCalled();
    });

    it('remove は 2 回目も冪等', async () => {
      prisma.event.findFirst.mockResolvedValue(eventRow({ deletedAt: NOW }));

      await expect(service.remove(USER_ID, EVENT_ID)).resolves.toBeUndefined();
      expect(prisma.event.update).not.toHaveBeenCalled();
    });
  });

  describe('upsertForApplication', () => {
    it('既存 event が無ければ ownerId / tourId をサーバー設定で作成する', async () => {
      prisma.event.findUnique.mockResolvedValue(null);
      prisma.event.create.mockResolvedValue(eventRow());

      await service.upsertForApplication(USER_ID, TOUR_ID, {
        id: EVENT_ID,
        name: '大阪公演 Day1',
        venue_name_raw: '大阪城ホール',
        event_date: '2026-08-20',
        starts_at: '2026-08-20T11:00:00.000Z',
      });

      expect(prisma.event.create).toHaveBeenCalledWith({
        data: {
          id: EVENT_ID,
          ownerId: USER_ID,
          tourId: TOUR_ID,
          name: '大阪公演 Day1',
          venueNameRaw: '大阪城ホール',
          eventDate: new Date('2026-08-20T00:00:00.000Z'),
          startsAt: new Date('2026-08-20T11:00:00.000Z'),
        },
      });
    });

    it('既存 event は name / venue / date / starts_at と deletedAt:null で更新する', async () => {
      prisma.event.findUnique.mockResolvedValue(eventRow({ deletedAt: NOW }));
      prisma.event.update.mockResolvedValue(eventRow());

      await service.upsertForApplication(USER_ID, TOUR_ID, {
        id: EVENT_ID,
        name: '大阪公演 Day1 (更新)',
      });

      expect(prisma.event.update).toHaveBeenCalledWith({
        where: { id: EVENT_ID },
        data: {
          tourId: TOUR_ID,
          name: '大阪公演 Day1 (更新)',
          deletedAt: null,
        },
      });
      expect(prisma.event.create).not.toHaveBeenCalled();
    });

    it('既存 event が他人のものなら NOT_FOUND 404（作成も更新もしない）', async () => {
      prisma.event.findUnique.mockResolvedValue(
        eventRow({ ownerId: OTHER_USER_ID }),
      );

      await expect(
        service.upsertForApplication(USER_ID, TOUR_ID, {
          id: EVENT_ID,
          name: '乗っ取り',
        }),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
      expect(prisma.event.update).not.toHaveBeenCalled();
      expect(prisma.event.create).not.toHaveBeenCalled();
    });

    it('tx を渡すと tx クライアント側で読み書きする', async () => {
      const tx = {
        event: {
          findUnique: jest.fn().mockResolvedValue(null),
          create: jest.fn().mockResolvedValue(eventRow()),
          update: jest.fn(),
        },
      };

      await service.upsertForApplication(
        USER_ID,
        TOUR_ID,
        { name: 'TX EVENT' },
        tx as never,
      );

      expect(tx.event.create).toHaveBeenCalled();
      expect(prisma.event.create).not.toHaveBeenCalled();
    });
  });
});
