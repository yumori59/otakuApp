import { PrismaService } from '../prisma/prisma.service';
import { IdentitiesService } from '../identities/identities.service';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { MembershipsService } from './memberships.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';
const MEMBERSHIP_ID = '018f3c2a-bbbb-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-01T00:00:00.000Z');

function membershipRow(overrides: Record<string, unknown> = {}) {
  return {
    id: MEMBERSHIP_ID,
    ownerId: USER_ID,
    identityId: IDENTITY_ID,
    fanClubNameRaw: 'STELLARIS OFFICIAL FAN CLUB',
    memberNoLast4: '4821',
    rank: 'プレミアム',
    renewalOn: null,
    feeYen: 5500,
    autoRenew: false,
    note: null,
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
    ...overrides,
  };
}

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

describe('MembershipsService', () => {
  let prisma: {
    membership: {
      findMany: jest.Mock;
      findFirst: jest.Mock;
      findUnique: jest.Mock;
      create: jest.Mock;
      update: jest.Mock;
    };
    application: { updateMany: jest.Mock };
    $transaction: jest.Mock;
  };
  let identities: { assertOwned: jest.Mock };
  let service: MembershipsService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      membership: {
        findMany: jest.fn(),
        findFirst: jest.fn(),
        findUnique: jest.fn().mockResolvedValue(null),
        create: jest.fn(),
        update: jest.fn(),
      },
      application: { updateMany: jest.fn() },
      $transaction: jest.fn((cb: (client: unknown) => unknown) => cb(prisma)),
    };
    identities = { assertOwned: jest.fn().mockResolvedValue(identityRow()) };
    service = new MembershipsService(
      prisma as unknown as PrismaService,
      identities as unknown as IdentitiesService,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('create', () => {
    it('AC-MB-01 他人の identity_id 配下には作成できず 404', async () => {
      identities.assertOwned.mockRejectedValue(
        AppError.notFound('identity not found'),
      );

      await expect(
        service.create(OTHER_USER_ID, {
          id: MEMBERSHIP_ID,
          identity_id: IDENTITY_ID,
          fan_club_name_raw: 'FC',
        }),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
      expect(prisma.membership.create).not.toHaveBeenCalled();
    });

    it('AC-MB-02 owner_id は親 identity の所有者 (userId) から継承される', async () => {
      prisma.membership.create.mockResolvedValue(membershipRow());

      await service.create(USER_ID, {
        id: MEMBERSHIP_ID,
        identity_id: IDENTITY_ID,
        fan_club_name_raw: 'FC',
      });

      expect(identities.assertOwned).toHaveBeenCalledWith(USER_ID, IDENTITY_ID);
      expect(prisma.membership.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({ ownerId: USER_ID, identityId: IDENTITY_ID }),
        }),
      );
    });

    it('BE-6 既存 id への再 POST は CONFLICT 409（Prisma に到達させない）', async () => {
      prisma.membership.findUnique.mockResolvedValue(membershipRow());

      await expect(
        service.create(USER_ID, {
          id: MEMBERSHIP_ID,
          identity_id: IDENTITY_ID,
          fan_club_name_raw: 'FC',
        }),
      ).rejects.toMatchObject({ code: ErrorCode.CONFLICT });
      expect(prisma.membership.findUnique).toHaveBeenCalledWith({
        where: { id: MEMBERSHIP_ID },
      });
      expect(prisma.membership.create).not.toHaveBeenCalled();
    });

    it('BE-6 ソフトデリート済みの id への再 POST も CONFLICT 409', async () => {
      prisma.membership.findUnique.mockResolvedValue(
        membershipRow({ deletedAt: NOW }),
      );

      await expect(
        service.create(USER_ID, {
          id: MEMBERSHIP_ID,
          identity_id: IDENTITY_ID,
          fan_club_name_raw: 'FC',
        }),
      ).rejects.toMatchObject({ code: ErrorCode.CONFLICT });
      expect(prisma.membership.create).not.toHaveBeenCalled();
    });

    it('auto_renew 省略時の既定は false', async () => {
      prisma.membership.create.mockResolvedValue(membershipRow());

      await service.create(USER_ID, {
        id: MEMBERSHIP_ID,
        identity_id: IDENTITY_ID,
        fan_club_name_raw: 'FC',
      });

      expect(prisma.membership.create).toHaveBeenCalledWith(
        expect.objectContaining({
          data: expect.objectContaining({ autoRenew: false }),
        }),
      );
    });
  });

  describe('list', () => {
    it('AC-MB-06 identity_id 指定時は親所有を検証しつつ絞り込む', async () => {
      prisma.membership.findMany.mockResolvedValue([]);

      await service.list(USER_ID, IDENTITY_ID);

      expect(identities.assertOwned).toHaveBeenCalledWith(USER_ID, IDENTITY_ID);
      expect(prisma.membership.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { ownerId: USER_ID, identityId: IDENTITY_ID, deletedAt: null },
        }),
      );
    });

    it('identity_id 未指定なら自分の全件（deletedAt:null）', async () => {
      prisma.membership.findMany.mockResolvedValue([]);

      await service.list(USER_ID, undefined);

      expect(identities.assertOwned).not.toHaveBeenCalled();
      expect(prisma.membership.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          where: { ownerId: USER_ID, deletedAt: null },
        }),
      );
    });

    it('並びは renewal_on asc nulls last, created_at asc', async () => {
      prisma.membership.findMany.mockResolvedValue([]);

      await service.list(USER_ID, undefined);

      expect(prisma.membership.findMany).toHaveBeenCalledWith(
        expect.objectContaining({
          orderBy: [
            { renewalOn: { sort: 'asc', nulls: 'last' } },
            { createdAt: 'asc' },
          ],
        }),
      );
    });

    it('AC-MB-08 renewal_on の日付文字列が往復して同じ文字列で返る', async () => {
      prisma.membership.findMany.mockResolvedValue([
        membershipRow({ renewalOn: new Date('2026-09-15T00:00:00.000Z') }),
      ]);

      const result = await service.list(USER_ID, undefined);

      expect(result[0].renewal_on).toBe('2026-09-15');
    });
  });

  describe('update / remove の ownerId スコープ', () => {
    it('他人の membership への update は NOT_FOUND', async () => {
      prisma.membership.findFirst.mockResolvedValue(null);

      await expect(
        service.update(OTHER_USER_ID, MEMBERSHIP_ID, { fan_club_name_raw: 'x' }),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
      expect(prisma.membership.update).not.toHaveBeenCalled();
    });

    it('他人の membership への remove は NOT_FOUND', async () => {
      prisma.membership.findFirst.mockResolvedValue(null);

      await expect(
        service.remove(OTHER_USER_ID, MEMBERSHIP_ID),
      ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
      expect(prisma.membership.update).not.toHaveBeenCalled();
    });
  });

  describe('update: identity_id 付け替え時の rep_membership_id 整合', () => {
    const NEW_IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000009';

    it('identity_id を付け替えたら、参照している application の rep_membership_id を TX 内でクリアする', async () => {
      prisma.membership.findFirst.mockResolvedValue(membershipRow());
      prisma.membership.update.mockResolvedValue(
        membershipRow({ identityId: NEW_IDENTITY_ID }),
      );

      await service.update(USER_ID, MEMBERSHIP_ID, {
        identity_id: NEW_IDENTITY_ID,
      });

      expect(prisma.$transaction).toHaveBeenCalledTimes(1);
      expect(prisma.application.updateMany).toHaveBeenCalledWith({
        where: {
          ownerId: USER_ID,
          repMembershipId: MEMBERSHIP_ID,
          deletedAt: null,
          repIdentityId: { not: NEW_IDENTITY_ID },
        },
        data: { repMembershipId: null },
      });
    });

    it('identity_id が同値なら application は触らない', async () => {
      prisma.membership.findFirst.mockResolvedValue(membershipRow());
      prisma.membership.update.mockResolvedValue(membershipRow());

      await service.update(USER_ID, MEMBERSHIP_ID, {
        identity_id: IDENTITY_ID,
      });

      expect(prisma.application.updateMany).not.toHaveBeenCalled();
    });

    it('identity_id 以外の更新では application を触らない', async () => {
      prisma.membership.findFirst.mockResolvedValue(membershipRow());
      prisma.membership.update.mockResolvedValue(membershipRow());

      await service.update(USER_ID, MEMBERSHIP_ID, { rank: 'ゴールド' });

      expect(prisma.application.updateMany).not.toHaveBeenCalled();
    });
  });

  describe('remove', () => {
    it('AC-MB-07 削除は行を消さず deletedAt を立てる（ソフトデリート）', async () => {
      prisma.membership.findFirst.mockResolvedValue(membershipRow());
      prisma.membership.update.mockResolvedValue(membershipRow({ deletedAt: NOW }));

      await service.remove(USER_ID, MEMBERSHIP_ID);

      expect(prisma.membership.update).toHaveBeenCalledWith({
        where: { id: MEMBERSHIP_ID },
        data: { deletedAt: NOW },
      });
    });

    it('2 回目の削除も冪等に成功する（update を呼ばない）', async () => {
      prisma.membership.findFirst.mockResolvedValue(
        membershipRow({ deletedAt: NOW }),
      );

      await expect(
        service.remove(USER_ID, MEMBERSHIP_ID),
      ).resolves.toBeUndefined();
      expect(prisma.membership.update).not.toHaveBeenCalled();
    });

    it('中-7: 削除時にこの membership を rep_membership_id として参照する application をクリアする（FR-AP-4）', async () => {
      prisma.membership.findFirst.mockResolvedValue(membershipRow());
      prisma.membership.update.mockResolvedValue(membershipRow({ deletedAt: NOW }));

      await service.remove(USER_ID, MEMBERSHIP_ID);

      expect(prisma.$transaction).toHaveBeenCalledTimes(1);
      expect(prisma.application.updateMany).toHaveBeenCalledWith({
        where: {
          ownerId: USER_ID,
          repMembershipId: MEMBERSHIP_ID,
          deletedAt: null,
        },
        data: { repMembershipId: null },
      });
    });
  });
});
