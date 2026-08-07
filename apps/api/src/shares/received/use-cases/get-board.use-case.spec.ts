import { ShareLink, ShareRecipient } from '@prisma/client';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { ResolveShareUseCase } from '../../board/use-cases/resolve-share.use-case';
import { ShareRecipientAccessService } from '../share-recipient-access.service';
import { GetBoardUseCase } from './get-board.use-case';

const OWNER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const RECIPIENT_ID = '018f3c2a-9999-7c90-9d2a-000000000002';
const STRANGER_ID = '018f3c2a-8888-7c90-9d2a-000000000003';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-02T10:00:00.000Z');

function shareLink(overrides: Partial<ShareLink> = {}): ShareLink {
  return {
    id: SHARE_ID,
    ownerId: OWNER_ID,
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
    createdAt: new Date('2026-07-01T00:00:00.000Z'),
    updatedAt: new Date('2026-07-01T00:00:00.000Z'),
    ...overrides,
  } as ShareLink;
}

function recipientRow(): ShareRecipient {
  return {
    id: '018f3c2a-2222-7c90-9d2a-000000000001',
    shareLinkId: SHARE_ID,
    accountId: 'ACC-7C1D02',
    userId: RECIPIENT_ID,
    hiddenAt: null,
    lastViewedAt: null,
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
  } as ShareRecipient;
}

describe('GetBoardUseCase', () => {
  let access: {
    findLinkById: jest.Mock;
    findRecipient: jest.Mock;
    markViewed: jest.Mock;
    findOwnerProfile: jest.Mock;
  };
  let resolveShare: { execute: jest.Mock };
  let useCase: GetBoardUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    access = {
      findLinkById: jest.fn().mockResolvedValue(shareLink()),
      findRecipient: jest.fn().mockResolvedValue(recipientRow()),
      markViewed: jest.fn().mockResolvedValue(undefined),
      findOwnerProfile: jest
        .fn()
        .mockResolvedValue({ accountId: 'ACC-7C1D02', displayName: 'みお' }),
    };
    resolveShare = {
      execute: jest.fn().mockResolvedValue({
        scope_type: 'tour',
        permission: 'read',
        tour: { name: 'STELLARIS LIVE TOUR 2026', artist_name: 'STELLARIS' },
        generated_at: NOW.toISOString(),
        items: [],
      }),
    };
    useCase = new GetBoardUseCase(
      access as unknown as ShareRecipientAccessService,
      resolveShare as unknown as ResolveShareUseCase,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('① :id が存在しない → 404 SHARE_INVALID', async () => {
    access.findLinkById.mockResolvedValue(null);

    const error = (await useCase
      .execute(RECIPIENT_ID, SHARE_ID)
      .catch((e: unknown) => e)) as AppError;

    expect(error).toBeInstanceOf(AppError);
    expect(error.code).toBe(ErrorCode.SHARE_INVALID);
    expect(error.getStatus()).toBe(404);
  });

  it('② 失効済みなら 404 SHARE_INVALID', async () => {
    access.findLinkById.mockResolvedValue(
      shareLink({ revokedAt: new Date('2026-07-15T00:00:00.000Z') }),
    );

    await expect(useCase.execute(RECIPIENT_ID, SHARE_ID)).rejects.toMatchObject(
      { code: ErrorCode.SHARE_INVALID },
    );
  });

  it('② 期限切れなら 404 SHARE_INVALID', async () => {
    access.findLinkById.mockResolvedValue(
      shareLink({ expiresAt: new Date('2026-08-01T00:00:00.000Z') }),
    );

    await expect(useCase.execute(RECIPIENT_ID, SHARE_ID)).rejects.toMatchObject(
      { code: ErrorCode.SHARE_INVALID },
    );
  });

  it('③ 呼び出し元がオーナーなら招待行を確認せず通す', async () => {
    const payload = await useCase.execute(OWNER_ID, SHARE_ID);

    expect(access.findRecipient).not.toHaveBeenCalled();
    expect(payload.share_id).toBe(SHARE_ID);
    expect(resolveShare.execute).toHaveBeenCalledWith(shareLink());
  });

  it('③ オーナー閲覧では share_recipients.last_viewed_at を更新しない', async () => {
    await useCase.execute(OWNER_ID, SHARE_ID);
    expect(access.markViewed).not.toHaveBeenCalled();
  });

  it('④ 招待されていない第三者は 404 SHARE_INVALID（403 にしない）', async () => {
    access.findRecipient.mockResolvedValue(null);

    const error = (await useCase
      .execute(STRANGER_ID, SHARE_ID)
      .catch((e: unknown) => e)) as AppError;

    expect(error).toBeInstanceOf(AppError);
    expect(error.code).toBe(ErrorCode.SHARE_INVALID);
    expect(error.getStatus()).toBe(404);
  });

  it('⑤ 招待済みの受け取り側は payload + share_id + owner を返し last_viewed_at を更新する', async () => {
    const payload = await useCase.execute(RECIPIENT_ID, SHARE_ID);

    expect(access.findRecipient).toHaveBeenCalledWith(SHARE_ID, RECIPIENT_ID);
    expect(resolveShare.execute).toHaveBeenCalledWith(shareLink());
    expect(access.markViewed).toHaveBeenCalledWith(SHARE_ID, RECIPIENT_ID, NOW);
    expect(payload).toEqual({
      scope_type: 'tour',
      permission: 'read',
      tour: { name: 'STELLARIS LIVE TOUR 2026', artist_name: 'STELLARIS' },
      generated_at: NOW.toISOString(),
      items: [],
      share_id: SHARE_ID,
      owner: { account_id: 'ACC-7C1D02', display_name: 'みお' },
    });
  });

  it('マスキングは ResolveShareUseCase に委譲する（NFR-7・再実装しない）', async () => {
    await useCase.execute(RECIPIENT_ID, SHARE_ID);
    expect(resolveShare.execute).toHaveBeenCalledTimes(1);
  });
});
