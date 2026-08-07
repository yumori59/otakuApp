import { ShareLink } from '@prisma/client';
import { ErrorCode } from '../../common/errors/error-codes';
import { PrismaService } from '../../prisma/prisma.service';
import { AddRecipientsDto } from '../dto/add-recipients.dto';
import { ShareRecipientsService } from '../share-recipients.service';
import { SharesService } from '../shares.service';
import { AddRecipientsUseCase } from './add-recipients.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OWN_ACCOUNT_ID = 'ACC-100000';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-02T10:00:00.000Z');

function shareRow(overrides: Partial<ShareLink> = {}): ShareLink {
  return {
    id: SHARE_ID,
    ownerId: USER_ID,
    scopeType: 'tour',
    scopeId: '018f3c2a-dddd-7c90-9d2a-000000000001',
    tokenHash: 'a'.repeat(64),
    permission: 'read',
    maskMemberNo: true,
    expiresAt: new Date('2026-08-31T00:00:00.000Z'),
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

describe('AddRecipientsUseCase', () => {
  let prisma: {
    shareLink: { findFirst: jest.Mock };
    profile: { findUnique: jest.Mock; findMany: jest.Mock };
    shareRecipient: {
      findMany: jest.Mock;
      createMany: jest.Mock;
    };
  };
  let shares: SharesService;
  let shareRecipients: ShareRecipientsService;
  let useCase: AddRecipientsUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      shareLink: { findFirst: jest.fn().mockResolvedValue(shareRow()) },
      profile: {
        findUnique: jest
          .fn()
          .mockResolvedValue({ accountId: OWN_ACCOUNT_ID }),
        findMany: jest
          .fn()
          .mockResolvedValue([
            { id: OTHER_USER_ID, accountId: 'ACC-1A2B3C', displayName: null },
          ]),
      },
      shareRecipient: {
        findMany: jest.fn().mockResolvedValue([]),
        createMany: jest.fn().mockResolvedValue(undefined),
      },
    };
    shareRecipients = new ShareRecipientsService(
      prisma as unknown as PrismaService,
    );
    shares = new SharesService(
      prisma as unknown as PrismaService,
      shareRecipients,
    );
    useCase = new AddRecipientsUseCase(shares, shareRecipients);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  function dto(overrides: Partial<AddRecipientsDto> = {}): AddRecipientsDto {
    return { account_ids: ['ACC-1A2B3C'], ...overrides } as AddRecipientsDto;
  }

  it('AC-SI-08 招待を追加でき、既存の招待は消えない', async () => {
    const res = await useCase.execute(USER_ID, SHARE_ID, dto());

    expect(prisma.shareRecipient.createMany).toHaveBeenCalledWith({
      data: [
        expect.objectContaining({
          shareLinkId: SHARE_ID,
          accountId: 'ACC-1A2B3C',
          userId: OTHER_USER_ID,
        }),
      ],
      skipDuplicates: true,
    });
    expect(res.recipients).toEqual([]);
  });

  it('AC-SI-08 既に招待済みの ACC-ID は冪等（新規追加分に数えない）', async () => {
    // 1 回目 = accountIdsByShareLink（既存招待の判定）。2 回目以降 = listByShareLink（応答組み立て）。
    prisma.shareRecipient.findMany.mockResolvedValueOnce([
      { accountId: 'ACC-1A2B3C' },
    ]);

    await useCase.execute(USER_ID, SHARE_ID, dto());

    expect(prisma.shareRecipient.createMany).not.toHaveBeenCalled();
  });

  it('AC-SI-10 他人の share :id は NOT_FOUND 404 (BE-4)', async () => {
    prisma.shareLink.findFirst.mockResolvedValue(null);

    await expect(
      useCase.execute(USER_ID, SHARE_ID, dto()),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    expect(prisma.shareRecipient.createMany).not.toHaveBeenCalled();
  });

  it('AC-SI-11 失効済みの share :id は NOT_FOUND 404', async () => {
    prisma.shareLink.findFirst.mockResolvedValue(
      shareRow({ revokedAt: new Date('2026-08-01T12:00:00.000Z') }),
    );

    await expect(
      useCase.execute(USER_ID, SHARE_ID, dto()),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
  });

  it('AC-SI-11 期限切れの share :id は NOT_FOUND 404', async () => {
    prisma.shareLink.findFirst.mockResolvedValue(
      shareRow({ expiresAt: new Date('2026-08-01T00:00:00.000Z') }),
    );

    await expect(
      useCase.execute(USER_ID, SHARE_ID, dto()),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
  });

  it('self の ACC-ID は SHARE_RECIPIENT_SELF 400', async () => {
    await expect(
      useCase.execute(
        USER_ID,
        SHARE_ID,
        dto({ account_ids: [OWN_ACCOUNT_ID] }),
      ),
    ).rejects.toMatchObject({ code: ErrorCode.SHARE_RECIPIENT_SELF });
    expect(prisma.shareRecipient.createMany).not.toHaveBeenCalled();
  });

  it('未知の ACC-ID は SHARE_RECIPIENT_UNKNOWN 400 + details', async () => {
    prisma.profile.findMany.mockResolvedValue([]);

    await expect(
      useCase.execute(
        USER_ID,
        SHARE_ID,
        dto({ account_ids: ['ACC-000000'] }),
      ),
    ).rejects.toMatchObject({
      code: ErrorCode.SHARE_RECIPIENT_UNKNOWN,
      details: { unknown_account_ids: ['ACC-000000'] },
    });
    expect(prisma.shareRecipient.createMany).not.toHaveBeenCalled();
  });

  it('AC-SI-07 / E-15 合計 20 件を超える追加は VALIDATION_ERROR 400', async () => {
    prisma.shareRecipient.findMany.mockResolvedValueOnce(
      Array.from({ length: 20 }, (_, i) => ({
        accountId: `ACC-${String(i).padStart(6, '0')}`,
      })),
    );

    await expect(
      useCase.execute(USER_ID, SHARE_ID, dto()),
    ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
    expect(prisma.shareRecipient.createMany).not.toHaveBeenCalled();
  });

  it('合計 20 件ちょうどは通る', async () => {
    prisma.shareRecipient.findMany.mockResolvedValueOnce(
      Array.from({ length: 19 }, (_, i) => ({
        accountId: `ACC-${String(i).padStart(6, '0')}`,
      })),
    );

    await expect(
      useCase.execute(USER_ID, SHARE_ID, dto()),
    ).resolves.toBeDefined();
    expect(prisma.shareRecipient.createMany).toHaveBeenCalled();
  });
});
