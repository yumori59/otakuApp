import { PrismaService } from '../../prisma/prisma.service';
import { ShareRecipientAccessService } from './share-recipient-access.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OWNER_ID = '018f3c2a-0000-7c90-9d2a-000000000009';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-02T10:00:00.000Z');

describe('ShareRecipientAccessService', () => {
  let prisma: {
    shareLink: { findUnique: jest.Mock; findMany: jest.Mock };
    shareRecipient: {
      findFirst: jest.Mock;
      findMany: jest.Mock;
      updateMany: jest.Mock;
    };
    profile: { findUnique: jest.Mock };
    tour: { findMany: jest.Mock };
  };
  let service: ShareRecipientAccessService;

  beforeEach(() => {
    prisma = {
      shareLink: { findUnique: jest.fn(), findMany: jest.fn() },
      shareRecipient: {
        findFirst: jest.fn(),
        findMany: jest.fn(),
        updateMany: jest.fn(),
      },
      profile: { findUnique: jest.fn() },
      tour: { findMany: jest.fn() },
    };
    service = new ShareRecipientAccessService(
      prisma as unknown as PrismaService,
    );
  });

  it('findLinkById は id で shareLink を検索する（token を経由しない）', async () => {
    prisma.shareLink.findUnique.mockResolvedValue({ id: SHARE_ID });
    const result = await service.findLinkById(SHARE_ID);
    expect(prisma.shareLink.findUnique).toHaveBeenCalledWith({
      where: { id: SHARE_ID },
    });
    expect(result).toEqual({ id: SHARE_ID });
  });

  it('findOwnerProfile はプロフィール未作成なら null を返す', async () => {
    prisma.profile.findUnique.mockResolvedValue(null);
    const result = await service.findOwnerProfile(OWNER_ID);
    expect(result).toBeNull();
  });

  it('findRecipient は (shareLinkId, userId) の招待行を探す', async () => {
    prisma.shareRecipient.findFirst.mockResolvedValue({ id: 'r1' });
    const result = await service.findRecipient(SHARE_ID, USER_ID);
    expect(prisma.shareRecipient.findFirst).toHaveBeenCalledWith({
      where: { shareLinkId: SHARE_ID, userId: USER_ID },
    });
    expect(result).toEqual({ id: 'r1' });
  });

  it('listInboxRows は自分宛て・非表示でない・失効/期限切れでない・オーナーが自分でない行だけを見る', async () => {
    prisma.shareRecipient.findMany.mockResolvedValue([]);
    await service.listInboxRows(USER_ID, NOW);

    expect(prisma.shareRecipient.findMany).toHaveBeenCalledWith({
      where: {
        userId: USER_ID,
        hiddenAt: null,
        shareLink: {
          revokedAt: null,
          ownerId: { not: USER_ID },
          OR: [{ expiresAt: null }, { expiresAt: { gt: NOW } }],
        },
      },
      orderBy: { createdAt: 'desc' },
      include: {
        shareLink: {
          include: { owner: { include: { profile: true } } },
        },
      },
    });
  });

  it('resolveTourNames は空配列なら Prisma を呼ばない', async () => {
    const result = await service.resolveTourNames([]);
    expect(result).toEqual(new Map());
    expect(prisma.tour.findMany).not.toHaveBeenCalled();
  });

  it('resolveTourNames は重複 id を除いて検索する', async () => {
    prisma.tour.findMany.mockResolvedValue([{ id: 't1', name: 'Tour 1' }]);
    const result = await service.resolveTourNames(['t1', 't1']);

    expect(prisma.tour.findMany).toHaveBeenCalledWith({
      where: { id: { in: ['t1'] } },
      select: { id: true, name: true },
    });
    expect(result.get('t1')).toBe('Tour 1');
  });

  it('markViewed は shareLinkId + userId で lastViewedAt を更新する', async () => {
    prisma.shareRecipient.updateMany.mockResolvedValue({ count: 1 });
    await service.markViewed(SHARE_ID, USER_ID, NOW);

    expect(prisma.shareRecipient.updateMany).toHaveBeenCalledWith({
      where: { shareLinkId: SHARE_ID, userId: USER_ID },
      data: { lastViewedAt: NOW },
    });
  });

  it('setHidden(true) は hiddenAt を立て、更新件数があれば true を返す', async () => {
    prisma.shareRecipient.updateMany.mockResolvedValue({ count: 1 });
    const result = await service.setHidden(SHARE_ID, USER_ID, true);

    expect(prisma.shareRecipient.updateMany).toHaveBeenCalledWith({
      where: { shareLinkId: SHARE_ID, userId: USER_ID },
      data: { hiddenAt: expect.any(Date) },
    });
    expect(result).toBe(true);
  });

  it('setHidden(false) は hiddenAt を null に戻す', async () => {
    prisma.shareRecipient.updateMany.mockResolvedValue({ count: 1 });
    await service.setHidden(SHARE_ID, USER_ID, false);

    expect(prisma.shareRecipient.updateMany).toHaveBeenCalledWith({
      where: { shareLinkId: SHARE_ID, userId: USER_ID },
      data: { hiddenAt: null },
    });
  });

  it('setHidden は招待行が無ければ false を返す（呼び出し元が 404 に変換する）', async () => {
    prisma.shareRecipient.updateMany.mockResolvedValue({ count: 0 });
    const result = await service.setHidden(SHARE_ID, USER_ID, true);
    expect(result).toBe(false);
  });
});
