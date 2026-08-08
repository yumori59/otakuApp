import { ShareRecipient } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';
import { ShareRecipientsService } from './share-recipients.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const SHARE_ID_A = '018f3c2a-1111-7c90-9d2a-000000000001';
const SHARE_ID_B = '018f3c2a-1111-7c90-9d2a-000000000002';

function recipientRow(overrides: Partial<ShareRecipient> = {}): ShareRecipient {
  return {
    id: '018f3c2a-2222-7c90-9d2a-000000000001',
    shareLinkId: SHARE_ID_A,
    accountId: 'ACC-3F9A21',
    userId: OTHER_USER_ID,
    hiddenAt: null,
    lastViewedAt: null,
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
    ...overrides,
  } as ShareRecipient;
}

describe('ShareRecipientsService', () => {
  let prisma: {
    profile: { findUnique: jest.Mock; findMany: jest.Mock };
    shareRecipient: {
      count: jest.Mock;
      findMany: jest.Mock;
      createMany: jest.Mock;
      deleteMany: jest.Mock;
    };
  };
  let service: ShareRecipientsService;

  beforeEach(() => {
    prisma = {
      profile: { findUnique: jest.fn(), findMany: jest.fn() },
      shareRecipient: {
        count: jest.fn(),
        findMany: jest.fn(),
        createMany: jest.fn(),
        deleteMany: jest.fn(),
      },
    };
    service = new ShareRecipientsService(prisma as unknown as PrismaService);
  });

  describe('resolveOwnAccountId', () => {
    it('profiles.account_id を返す', async () => {
      prisma.profile.findUnique.mockResolvedValue({ accountId: 'ACC-100000' });

      const accountId = await service.resolveOwnAccountId(USER_ID);

      expect(prisma.profile.findUnique).toHaveBeenCalledWith({
        where: { id: USER_ID },
        select: { accountId: true },
      });
      expect(accountId).toBe('ACC-100000');
    });

    it('プロフィール未作成 / account_id 未発行なら null', async () => {
      prisma.profile.findUnique.mockResolvedValue(null);
      await expect(service.resolveOwnAccountId(USER_ID)).resolves.toBeNull();

      prisma.profile.findUnique.mockResolvedValue({ accountId: null });
      await expect(service.resolveOwnAccountId(USER_ID)).resolves.toBeNull();
    });
  });

  describe('resolveAccountIds', () => {
    it('AC-SI-02 実在する ACC-ID を resolved、実在しないものを unknown に振り分ける', async () => {
      prisma.profile.findMany.mockResolvedValue([
        { id: OTHER_USER_ID, accountId: 'ACC-3F9A21', displayName: 'ゆう' },
      ]);

      const { resolved, unknown } = await service.resolveAccountIds([
        'ACC-3F9A21',
        'ACC-000000',
      ]);

      expect(prisma.profile.findMany).toHaveBeenCalledWith({
        where: { accountId: { in: ['ACC-3F9A21', 'ACC-000000'] } },
        select: { id: true, accountId: true, displayName: true },
      });
      expect(resolved).toEqual([
        { accountId: 'ACC-3F9A21', userId: OTHER_USER_ID, displayName: 'ゆう' },
      ]);
      expect(unknown).toEqual(['ACC-000000']);
    });

    it('空配列は DB を引かずに空を返す', async () => {
      const result = await service.resolveAccountIds([]);
      expect(prisma.profile.findMany).not.toHaveBeenCalled();
      expect(result).toEqual({ resolved: [], unknown: [] });
    });
  });

  describe('accountIdsByShareLink / countByShareLink', () => {
    it('shareLinkId スコープの account_id 集合を返す', async () => {
      prisma.shareRecipient.findMany.mockResolvedValue([
        { accountId: 'ACC-3F9A21' },
        { accountId: 'ACC-9F8E7D' },
      ]);

      const ids = await service.accountIdsByShareLink(SHARE_ID_A);

      expect(prisma.shareRecipient.findMany).toHaveBeenCalledWith({
        where: { shareLinkId: SHARE_ID_A },
        select: { accountId: true },
      });
      expect(ids).toEqual(new Set(['ACC-3F9A21', 'ACC-9F8E7D']));
    });

    it('件数を返す', async () => {
      prisma.shareRecipient.count.mockResolvedValue(3);
      await expect(service.countByShareLink(SHARE_ID_A)).resolves.toBe(3);
      expect(prisma.shareRecipient.count).toHaveBeenCalledWith({
        where: { shareLinkId: SHARE_ID_A },
      });
    });
  });

  describe('addMany', () => {
    it('AC-SI-08 skipDuplicates で既存 ACC-ID を無視する（invited_at を更新しない）', async () => {
      await service.addMany(SHARE_ID_A, [
        { accountId: 'ACC-3F9A21', userId: OTHER_USER_ID },
      ]);

      expect(prisma.shareRecipient.createMany).toHaveBeenCalledWith({
        data: [
          expect.objectContaining({
            shareLinkId: SHARE_ID_A,
            accountId: 'ACC-3F9A21',
            userId: OTHER_USER_ID,
          }),
        ],
        skipDuplicates: true,
      });
    });

    it('0 件なら createMany を呼ばない', async () => {
      await service.addMany(SHARE_ID_A, []);
      expect(prisma.shareRecipient.createMany).not.toHaveBeenCalled();
    });
  });

  describe('remove', () => {
    it('AC-SI-09 shareLinkId + accountId で deleteMany する（存在しなくても成功・冪等）', async () => {
      prisma.shareRecipient.deleteMany.mockResolvedValue({ count: 0 });

      await expect(
        service.remove(SHARE_ID_A, 'ACC-000000'),
      ).resolves.toBeUndefined();
      expect(prisma.shareRecipient.deleteMany).toHaveBeenCalledWith({
        where: { shareLinkId: SHARE_ID_A, accountId: 'ACC-000000' },
      });
    });
  });

  describe('listByShareLink', () => {
    it('display_name を解決して invited_at 昇順で返す', async () => {
      prisma.shareRecipient.findMany.mockResolvedValue([recipientRow()]);
      prisma.profile.findMany.mockResolvedValue([
        { id: OTHER_USER_ID, displayName: 'ゆう' },
      ]);

      const recipients = await service.listByShareLink(SHARE_ID_A);

      expect(prisma.shareRecipient.findMany).toHaveBeenCalledWith({
        where: { shareLinkId: SHARE_ID_A },
        orderBy: { createdAt: 'asc' },
      });
      expect(recipients).toEqual([
        {
          account_id: 'ACC-3F9A21',
          display_name: 'ゆう',
          invited_at: '2026-08-01T00:00:00.000Z',
          last_viewed_at: null,
        },
      ]);
    });

    it('recipients に hidden_at を含めない（Q3）', async () => {
      prisma.shareRecipient.findMany.mockResolvedValue([
        recipientRow({ hiddenAt: new Date('2026-08-02T00:00:00.000Z') }),
      ]);
      prisma.profile.findMany.mockResolvedValue([]);

      const recipients = await service.listByShareLink(SHARE_ID_A);

      expect(Object.keys(recipients[0])).not.toContain('hidden_at');
    });

    it('display_name が無いプロフィールは null', async () => {
      prisma.shareRecipient.findMany.mockResolvedValue([recipientRow()]);
      prisma.profile.findMany.mockResolvedValue([]);

      const recipients = await service.listByShareLink(SHARE_ID_A);

      expect(recipients[0].display_name).toBeNull();
    });
  });

  describe('listByShareLinks', () => {
    it('複数 shareLinkId をまとめて解決する（N+1 回避）', async () => {
      prisma.shareRecipient.findMany.mockResolvedValue([
        recipientRow({ shareLinkId: SHARE_ID_A, accountId: 'ACC-3F9A21' }),
        recipientRow({ shareLinkId: SHARE_ID_B, accountId: 'ACC-9F8E7D' }),
      ]);
      prisma.profile.findMany.mockResolvedValue([
        { id: OTHER_USER_ID, displayName: 'ゆう' },
      ]);

      const byId = await service.listByShareLinks([SHARE_ID_A, SHARE_ID_B]);

      expect(prisma.shareRecipient.findMany).toHaveBeenCalledWith({
        where: { shareLinkId: { in: [SHARE_ID_A, SHARE_ID_B] } },
        orderBy: { createdAt: 'asc' },
      });
      expect(byId.get(SHARE_ID_A)).toEqual([
        expect.objectContaining({ account_id: 'ACC-3F9A21' }),
      ]);
      expect(byId.get(SHARE_ID_B)).toEqual([
        expect.objectContaining({ account_id: 'ACC-9F8E7D' }),
      ]);
    });

    it('空配列は DB を引かずに空 Map を返す', async () => {
      const byId = await service.listByShareLinks([]);
      expect(prisma.shareRecipient.findMany).not.toHaveBeenCalled();
      expect(byId.size).toBe(0);
    });
  });
});
