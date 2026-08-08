import { Application } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';
import { SharedApplicationsService } from './shared-applications.service';

const OWNER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const APPLICATION_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';
const UPDATED_AT = new Date('2026-08-02T10:00:00.000Z');

function applicationRow(overrides: Partial<Application> = {}): Application {
  return {
    id: APPLICATION_ID,
    ownerId: OWNER_ID,
    status: 'applied',
    seatRaw: null,
    updatedAt: UPDATED_AT,
    deletedAt: null,
    ...overrides,
  } as Application;
}

describe('SharedApplicationsService', () => {
  let tx: {
    application: { updateMany: jest.Mock; findUnique: jest.Mock };
  };
  let prisma: {
    application: { findMany: jest.Mock; findFirst: jest.Mock };
    $transaction: jest.Mock;
  };
  let service: SharedApplicationsService;

  beforeEach(() => {
    tx = {
      application: {
        updateMany: jest.fn().mockResolvedValue({ count: 1 }),
        findUnique: jest.fn().mockResolvedValue(applicationRow()),
      },
    };
    prisma = {
      application: { findMany: jest.fn(), findFirst: jest.fn() },
      $transaction: jest.fn((fn: (client: unknown) => unknown) => fn(tx)),
    };
    service = new SharedApplicationsService(prisma as unknown as PrismaService);
  });

  describe('findUpdatedAtByTour', () => {
    it('ownerId + 未削除 + 対象 tour でスコープする (BE-4)', async () => {
      prisma.application.findMany.mockResolvedValue([
        { id: APPLICATION_ID, updatedAt: UPDATED_AT },
      ]);

      const map = await service.findUpdatedAtByTour(OWNER_ID, TOUR_ID);

      expect(prisma.application.findMany).toHaveBeenCalledWith({
        where: {
          ownerId: OWNER_ID,
          deletedAt: null,
          event: { tourId: TOUR_ID, ownerId: OWNER_ID, deletedAt: null },
        },
        select: { id: true, updatedAt: true },
      });
      expect(map.get(APPLICATION_ID)).toEqual(UPDATED_AT);
    });
  });

  describe('findOwned', () => {
    it('他人 / 削除済みは null（ownerId スコープ — BE-4）', async () => {
      prisma.application.findFirst.mockResolvedValue(null);

      await expect(service.findOwned(OWNER_ID, APPLICATION_ID)).resolves.toBeNull();
      expect(prisma.application.findFirst).toHaveBeenCalledWith({
        where: { id: APPLICATION_ID, ownerId: OWNER_ID, deletedAt: null },
      });
    });
  });

  describe('updateIfUnchanged', () => {
    it('AC-SW-11 updated_at 一致時だけ更新し、更新後の行を返す', async () => {
      const updated = applicationRow({
        status: 'won',
        updatedAt: new Date('2026-08-02T12:00:00.000Z'),
      });
      tx.application.findUnique.mockResolvedValue(updated);

      const row = await service.updateIfUnchanged(
        OWNER_ID,
        APPLICATION_ID,
        UPDATED_AT,
        { status: 'won' },
      );

      expect(tx.application.updateMany).toHaveBeenCalledWith({
        where: {
          id: APPLICATION_ID,
          ownerId: OWNER_ID,
          deletedAt: null,
          updatedAt: UPDATED_AT,
        },
        data: { status: 'won' },
      });
      expect(row).toBe(updated);
    });

    it('AC-SW-18 updated_at 不一致なら書き込まずに null', async () => {
      tx.application.updateMany.mockResolvedValue({ count: 0 });

      const row = await service.updateIfUnchanged(
        OWNER_ID,
        APPLICATION_ID,
        UPDATED_AT,
        { status: 'won' },
      );

      expect(row).toBeNull();
      expect(tx.application.findUnique).not.toHaveBeenCalled();
    });

    it('更新と読み直しを同一 TX で行う', async () => {
      await service.updateIfUnchanged(OWNER_ID, APPLICATION_ID, UPDATED_AT, {
        seatRaw: null,
      });

      expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    });
  });
});
