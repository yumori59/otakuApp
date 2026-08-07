import { ShareLink } from '@prisma/client';
import { ErrorCode } from '../../common/errors/error-codes';
import { PrismaService } from '../../prisma/prisma.service';
import { ShareRecipientsService } from '../share-recipients.service';
import { SharesService } from '../shares.service';
import { RemoveRecipientUseCase } from './remove-recipient.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';

function shareRow(overrides: Partial<ShareLink> = {}): ShareLink {
  return {
    id: SHARE_ID,
    ownerId: USER_ID,
    scopeType: 'tour',
    scopeId: '018f3c2a-dddd-7c90-9d2a-000000000001',
    tokenHash: 'a'.repeat(64),
    permission: 'read',
    maskMemberNo: true,
    expiresAt: null,
    revokedAt: null,
    viewCount: 0,
    lastViewedAt: null,
    editCount: 0,
    lastEditedAt: null,
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
    ...overrides,
  } as ShareLink;
}

describe('RemoveRecipientUseCase', () => {
  let prisma: {
    shareLink: { findFirst: jest.Mock };
    shareRecipient: { deleteMany: jest.Mock };
  };
  let useCase: RemoveRecipientUseCase;

  beforeEach(() => {
    prisma = {
      shareLink: { findFirst: jest.fn().mockResolvedValue(shareRow()) },
      shareRecipient: {
        deleteMany: jest.fn().mockResolvedValue({ count: 1 }),
      },
    };
    const shareRecipients = new ShareRecipientsService(
      prisma as unknown as PrismaService,
    );
    const shares = new SharesService(
      prisma as unknown as PrismaService,
      shareRecipients,
    );
    useCase = new RemoveRecipientUseCase(shares, shareRecipients);
  });

  it('AC-SI-09 存在する ACC-ID を削除する', async () => {
    await useCase.execute(USER_ID, SHARE_ID, 'ACC-1A2B3C');

    expect(prisma.shareRecipient.deleteMany).toHaveBeenCalledWith({
      where: { shareLinkId: SHARE_ID, accountId: 'ACC-1A2B3C' },
    });
  });

  it('AC-SI-09 存在しない ACC-ID でも成功する（冪等・204 相当）', async () => {
    prisma.shareRecipient.deleteMany.mockResolvedValue({ count: 0 });

    await expect(
      useCase.execute(USER_ID, SHARE_ID, 'ACC-000000'),
    ).resolves.toBeUndefined();
  });

  it('AC-SI-10 他人の share :id は NOT_FOUND 404 (BE-4)', async () => {
    prisma.shareLink.findFirst.mockResolvedValue(null);

    await expect(
      useCase.execute(USER_ID, SHARE_ID, 'ACC-1A2B3C'),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    expect(prisma.shareRecipient.deleteMany).not.toHaveBeenCalled();
  });

  it('AC-SI-12 最後の 1 人を削除しても成功する（失効済みでも許可）', async () => {
    prisma.shareLink.findFirst.mockResolvedValue(
      shareRow({ revokedAt: new Date('2026-08-01T12:00:00.000Z') }),
    );

    await expect(
      useCase.execute(USER_ID, SHARE_ID, 'ACC-1A2B3C'),
    ).resolves.toBeUndefined();
    expect(prisma.shareRecipient.deleteMany).toHaveBeenCalled();
  });
});
