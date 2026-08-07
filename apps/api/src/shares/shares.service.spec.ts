import { ShareLink } from '@prisma/client';
import { ErrorCode } from '../common/errors/error-codes';
import { sha256Hex } from '../common/util/hash.util';
import { PrismaService } from '../prisma/prisma.service';
import { SharesService } from './shares.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-02T10:00:00.000Z');

function shareRow(overrides: Partial<ShareLink> = {}): ShareLink {
  return {
    id: SHARE_ID,
    ownerId: USER_ID,
    scopeType: 'tour',
    scopeId: TOUR_ID,
    tokenHash: 'a'.repeat(64),
    permission: 'read',
    maskMemberNo: true,
    expiresAt: new Date('2026-08-31T00:00:00.000Z'),
    revokedAt: null,
    viewCount: 0,
    lastViewedAt: null,
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
    ...overrides,
  } as ShareLink;
}

describe('SharesService', () => {
  let prisma: {
    shareLink: {
      findMany: jest.Mock;
      findFirst: jest.Mock;
      findUnique: jest.Mock;
      count: jest.Mock;
      create: jest.Mock;
      update: jest.Mock;
    };
    tour: { findMany: jest.Mock };
    event: { count: jest.Mock };
  };
  let service: SharesService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      shareLink: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        findUnique: jest.fn(),
        count: jest.fn(),
        create: jest.fn(),
        update: jest.fn(),
      },
      tour: { findMany: jest.fn() },
      event: { count: jest.fn() },
    };
    service = new SharesService(prisma as unknown as PrismaService);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('create', () => {
    it('AC-SH-01 DB には sha256 hex だけを保存し、生トークンを返す', async () => {
      prisma.shareLink.create.mockImplementation(({ data }) =>
        Promise.resolve(shareRow(data as Partial<ShareLink>)),
      );

      const { token, row } = await service.create(USER_ID, {
        scopeType: 'tour',
        scopeId: TOUR_ID,
        permission: 'read',
        maskMemberNo: true,
        expiresAt: new Date('2026-08-31T00:00:00.000Z'),
      });

      const data = prisma.shareLink.create.mock.calls[0][0].data as Record<
        string,
        unknown
      >;
      expect(token.length).toBeGreaterThan(20);
      expect(data.tokenHash).toBe(sha256Hex(token));
      expect(data.tokenHash).not.toBe(token);
      expect(JSON.stringify(data)).not.toContain(token);
      expect(data.ownerId).toBe(USER_ID);
      expect(data.permission).toBe('read');
      expect(typeof data.id).toBe('string');
      expect(row.scopeType).toBe('tour');
    });

    it('AC-SW-02 permission を渡した値のまま保存する（read にハードコードしない）', async () => {
      prisma.shareLink.create.mockImplementation(({ data }) =>
        Promise.resolve(shareRow(data as Partial<ShareLink>)),
      );

      const { row } = await service.create(USER_ID, {
        scopeType: 'tour',
        scopeId: TOUR_ID,
        permission: 'write',
        maskMemberNo: true,
        expiresAt: null,
      });

      const data = prisma.shareLink.create.mock.calls[0][0].data as Record<
        string,
        unknown
      >;
      expect(data.permission).toBe('write');
      expect(row.permission).toBe('write');
    });
  });

  describe('countActive', () => {
    it('AC-SH-03 失効済み / 期限切れは数えない', async () => {
      prisma.shareLink.count.mockResolvedValue(1);

      const count = await service.countActive(USER_ID, NOW);

      expect(count).toBe(1);
      expect(prisma.shareLink.count).toHaveBeenCalledWith({
        where: {
          ownerId: USER_ID,
          revokedAt: null,
          OR: [{ expiresAt: null }, { expiresAt: { gt: NOW } }],
        },
      });
    });
  });

  describe('list', () => {
    it('ownerId スコープ + created_at desc で返す (BE-4)', async () => {
      prisma.shareLink.findMany.mockResolvedValue([shareRow()]);
      prisma.tour.findMany.mockResolvedValue([
        { id: TOUR_ID, name: 'STELLARIS LIVE TOUR 2026' },
      ]);

      const items = await service.list(USER_ID);

      expect(prisma.shareLink.findMany).toHaveBeenCalledWith({
        where: { ownerId: USER_ID },
        orderBy: { createdAt: 'desc' },
      });
      expect(items).toHaveLength(1);
      expect(items[0].scope_name).toBe('STELLARIS LIVE TOUR 2026');
      expect(items[0].is_active).toBe(true);
    });

    it('scope_name の tour 検索も ownerId スコープ (BE-4)', async () => {
      prisma.shareLink.findMany.mockResolvedValue([shareRow()]);
      prisma.tour.findMany.mockResolvedValue([]);

      const items = await service.list(USER_ID);

      expect(prisma.tour.findMany).toHaveBeenCalledWith({
        where: { id: { in: [TOUR_ID] }, ownerId: USER_ID },
        select: { id: true, name: true },
      });
      expect(items[0].scope_name).toBeNull();
    });

    it('identity_summary だけなら tour を引かない', async () => {
      prisma.shareLink.findMany.mockResolvedValue([
        shareRow({ scopeType: 'identity_summary', scopeId: null }),
      ]);

      const items = await service.list(USER_ID);

      expect(prisma.tour.findMany).not.toHaveBeenCalled();
      expect(items[0].scope_name).toBeNull();
    });
  });

  describe('revoke', () => {
    it('AC-SH-10 revoked_at が now で入る', async () => {
      prisma.shareLink.findFirst.mockResolvedValue(shareRow());
      prisma.shareLink.update.mockResolvedValue(shareRow({ revokedAt: NOW }));

      await service.revoke(USER_ID, SHARE_ID);

      expect(prisma.shareLink.findFirst).toHaveBeenCalledWith({
        where: { id: SHARE_ID, ownerId: USER_ID },
      });
      expect(prisma.shareLink.update).toHaveBeenCalledWith({
        where: { id: SHARE_ID },
        data: { revokedAt: NOW },
      });
    });

    it('AC-SH-10 2 回目は更新せずに成功する（冪等）', async () => {
      prisma.shareLink.findFirst.mockResolvedValue(
        shareRow({ revokedAt: new Date('2026-08-01T12:00:00.000Z') }),
      );

      await expect(service.revoke(USER_ID, SHARE_ID)).resolves.toBeUndefined();
      expect(prisma.shareLink.update).not.toHaveBeenCalled();
    });

    it('AC-SH-10 他人の id は NOT_FOUND 404 (BE-4)', async () => {
      prisma.shareLink.findFirst.mockResolvedValue(null);

      await expect(
        service.revoke(OTHER_USER_ID, SHARE_ID),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
      expect(prisma.shareLink.update).not.toHaveBeenCalled();
    });
  });

  describe('findByToken', () => {
    it('生トークンを sha256 して照合する（平文で検索しない）', async () => {
      prisma.shareLink.findUnique.mockResolvedValue(shareRow());

      const row = await service.findByToken('raw-token');

      expect(prisma.shareLink.findUnique).toHaveBeenCalledWith({
        where: { tokenHash: sha256Hex('raw-token') },
      });
      expect(row).not.toBeNull();
    });

    it('空トークンは DB を引かずに null', async () => {
      const row = await service.findByToken('');

      expect(prisma.shareLink.findUnique).not.toHaveBeenCalled();
      expect(row).toBeNull();
    });
  });

  describe('recordView', () => {
    it('AC-SH-13 view_count を +1 し last_viewed_at を更新する', async () => {
      prisma.shareLink.update.mockResolvedValue(shareRow());

      await service.recordView(SHARE_ID, NOW);

      expect(prisma.shareLink.update).toHaveBeenCalledWith({
        where: { id: SHARE_ID },
        data: { viewCount: { increment: 1 }, lastViewedAt: NOW },
      });
    });
  });

  describe('recordEdit', () => {
    it('AC-SW-20 / AC-SW-21 edit_count だけを +1 し view_count は触らない', async () => {
      prisma.shareLink.update.mockResolvedValue(shareRow());

      await service.recordEdit(SHARE_ID, NOW);

      expect(prisma.shareLink.update).toHaveBeenCalledWith({
        where: { id: SHARE_ID },
        data: { editCount: { increment: 1 }, lastEditedAt: NOW },
      });
      const data = prisma.shareLink.update.mock.calls[0][0].data as Record<
        string,
        unknown
      >;
      expect(Object.keys(data)).not.toContain('viewCount');
      expect(Object.keys(data)).not.toContain('lastViewedAt');
    });
  });

  describe('countTourEvents', () => {
    it('AC-SW-05d 未削除 event だけを ownerId スコープで数える (BE-4)', async () => {
      prisma.event.count.mockResolvedValue(4);

      const count = await service.countTourEvents(USER_ID, TOUR_ID);

      expect(count).toBe(4);
      expect(prisma.event.count).toHaveBeenCalledWith({
        where: { tourId: TOUR_ID, ownerId: USER_ID, deletedAt: null },
      });
    });
  });
});
