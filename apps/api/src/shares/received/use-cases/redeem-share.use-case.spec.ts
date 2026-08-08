import { ShareLink, ShareRecipient } from '@prisma/client';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { SharesService } from '../../shares.service';
import { ShareRecipientAccessService } from '../share-recipient-access.service';
import { RedeemShareUseCase } from './redeem-share.use-case';

const OWNER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const RECIPIENT_ID = '018f3c2a-9999-7c90-9d2a-000000000002';
const STRANGER_ID = '018f3c2a-8888-7c90-9d2a-000000000003';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-02T10:00:00.000Z');
const RAW_TOKEN = 'raw-opaque-share-token';

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
    viewCount: 3,
    lastViewedAt: null,
    editCount: 0,
    lastEditedAt: null,
    createdAt: new Date('2026-07-01T00:00:00.000Z'),
    updatedAt: new Date('2026-07-01T00:00:00.000Z'),
    ...overrides,
  } as ShareLink;
}

describe('RedeemShareUseCase', () => {
  let shares: { findByToken: jest.Mock };
  let access: { findRecipient: jest.Mock };
  let useCase: RedeemShareUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    shares = { findByToken: jest.fn().mockResolvedValue(shareLink()) };
    access = {
      findRecipient: jest.fn().mockResolvedValue({
        id: '018f3c2a-2222-7c90-9d2a-000000000001',
      } as ShareRecipient),
    };
    useCase = new RedeemShareUseCase(
      shares as unknown as SharesService,
      access as unknown as ShareRecipientAccessService,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it.each([
    ['未知トークン', null],
    ['失効済み', shareLink({ revokedAt: new Date('2026-07-15T00:00:00.000Z') })],
    ['期限切れ', shareLink({ expiresAt: new Date('2026-08-01T00:00:00.000Z') })],
  ])('AC-SI-25 %s は 3 者を区別せず 404 SHARE_INVALID', async (_label, row) => {
    shares.findByToken.mockResolvedValue(row);

    const error = (await useCase
      .execute(RECIPIENT_ID, RAW_TOKEN)
      .catch((e: unknown) => e)) as AppError;

    expect(error).toBeInstanceOf(AppError);
    expect(error.code).toBe(ErrorCode.SHARE_INVALID);
    expect(error.getStatus()).toBe(404);
    expect(access.findRecipient).not.toHaveBeenCalled();
  });

  it('AC-SI-26 有効トークン + 招待済みは 200 { share_id }', async () => {
    const result = await useCase.execute(RECIPIENT_ID, RAW_TOKEN);
    expect(result).toEqual({ share_id: SHARE_ID });
    expect(access.findRecipient).toHaveBeenCalledWith(SHARE_ID, RECIPIENT_ID);
  });

  it('AC-SI-26 有効トークン + オーナー本人は招待行を確認せず 200 { share_id }', async () => {
    const result = await useCase.execute(OWNER_ID, RAW_TOKEN);
    expect(result).toEqual({ share_id: SHARE_ID });
    expect(access.findRecipient).not.toHaveBeenCalled();
  });

  it('AC-SI-27 有効トークン + 招待されていない第三者は 403 SHARE_NOT_INVITED', async () => {
    access.findRecipient.mockResolvedValue(null);

    const error = (await useCase
      .execute(STRANGER_ID, RAW_TOKEN)
      .catch((e: unknown) => e)) as AppError;

    expect(error).toBeInstanceOf(AppError);
    expect(error.code).toBe(ErrorCode.SHARE_NOT_INVITED);
    expect(error.getStatus()).toBe(403);
  });

  it('AC-SI-28 副作用なし（SharesService は findByToken 以外を呼ばない）', async () => {
    await useCase.execute(RECIPIENT_ID, RAW_TOKEN);
    expect(shares.findByToken).toHaveBeenCalledTimes(1);
  });
});
