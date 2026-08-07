import { ShareLink, ShareRecipient } from '@prisma/client';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { UpdateShareItemUseCase } from '../../board/use-cases/update-share-item.use-case';
import { UpdateShareItemDto } from '../../board/dto/update-share-item.dto';
import { ShareRecipientAccessService } from '../share-recipient-access.service';
import { UpdateItemUseCase } from './update-item.use-case';

const OWNER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const RECIPIENT_ID = '018f3c2a-9999-7c90-9d2a-000000000002';
const STRANGER_ID = '018f3c2a-8888-7c90-9d2a-000000000003';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const ITEM_KEY = 'jK3n0pQrStUvWxYz';
const NOW = new Date('2026-08-02T10:00:00.000Z');

function shareLink(overrides: Partial<ShareLink> = {}): ShareLink {
  return {
    id: SHARE_ID,
    ownerId: OWNER_ID,
    scopeType: 'tour',
    scopeId: '018f3c2a-dddd-7c90-9d2a-000000000001',
    tokenHash: 'a'.repeat(64),
    permission: 'write',
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

function dto(): UpdateShareItemDto {
  return { rev: 'AbCdEfGhIjKlMnOp', status: 'won' } as UpdateShareItemDto;
}

describe('UpdateItemUseCase', () => {
  let access: { findLinkById: jest.Mock; findRecipient: jest.Mock };
  let updateShareItem: { execute: jest.Mock };
  let useCase: UpdateItemUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    access = {
      findLinkById: jest.fn().mockResolvedValue(shareLink()),
      findRecipient: jest.fn().mockResolvedValue(recipientRow()),
    };
    updateShareItem = {
      execute: jest.fn().mockResolvedValue({ item_key: ITEM_KEY }),
    };
    useCase = new UpdateItemUseCase(
      access as unknown as ShareRecipientAccessService,
      updateShareItem as unknown as UpdateShareItemUseCase,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('① :id の有効性', () => {
    const cases: Array<[string, ShareLink | null]> = [
      ['未知の :id', null],
      ['失効済み', shareLink({ revokedAt: new Date('2026-07-15T00:00:00.000Z') })],
      ['期限切れ', shareLink({ expiresAt: new Date('2026-08-02T09:59:59.999Z') })],
      ['期限ちょうど', shareLink({ expiresAt: NOW })],
    ];

    it.each(cases)('%s は SHARE_INVALID 404・書き込みに進まない', async (_label, link) => {
      access.findLinkById.mockResolvedValue(link);

      const error = (await useCase
        .execute(RECIPIENT_ID, SHARE_ID, ITEM_KEY, dto())
        .catch((e: unknown) => e)) as AppError;

      expect(error).toBeInstanceOf(AppError);
      expect(error.code).toBe(ErrorCode.SHARE_INVALID);
      expect(error.getStatus()).toBe(404);
      expect(updateShareItem.execute).not.toHaveBeenCalled();
    });
  });

  describe('② 招待判定（permission 判定より前 — AC-SI-29）', () => {
    it('AC-SI-29 read リンクに非招待者が来たら 403 ではなく 404 SHARE_INVALID', async () => {
      access.findLinkById.mockResolvedValue(shareLink({ permission: 'read' }));
      access.findRecipient.mockResolvedValue(null);

      const error = (await useCase
        .execute(STRANGER_ID, SHARE_ID, ITEM_KEY, dto())
        .catch((e: unknown) => e)) as AppError;

      expect(error).toBeInstanceOf(AppError);
      expect(error.code).toBe(ErrorCode.SHARE_INVALID);
      expect(error.getStatus()).toBe(404);
      // permission 判定（③）を担う use case まで到達させない
      expect(updateShareItem.execute).not.toHaveBeenCalled();
    });

    it('AC-SI-29 write リンクの非招待者も同じ 404（本文まで完全一致 = read/write を判別させない）', async () => {
      access.findRecipient.mockResolvedValue(null);
      const onWrite = (await useCase
        .execute(STRANGER_ID, SHARE_ID, ITEM_KEY, dto())
        .catch((e: unknown) => e)) as AppError;

      access.findLinkById.mockResolvedValue(shareLink({ permission: 'read' }));
      const onRead = (await useCase
        .execute(STRANGER_ID, SHARE_ID, ITEM_KEY, dto())
        .catch((e: unknown) => e)) as AppError;

      expect(JSON.stringify(onWrite.getResponse())).toBe(
        JSON.stringify(onRead.getResponse()),
      );
    });

    it('未知の :id と非招待者の :id でエラー本文が完全一致する（存在を推測させない）', async () => {
      access.findLinkById.mockResolvedValue(null);
      const unknown = (await useCase
        .execute(STRANGER_ID, SHARE_ID, ITEM_KEY, dto())
        .catch((e: unknown) => e)) as AppError;

      access.findLinkById.mockResolvedValue(shareLink());
      access.findRecipient.mockResolvedValue(null);
      const notInvited = (await useCase
        .execute(STRANGER_ID, SHARE_ID, ITEM_KEY, dto())
        .catch((e: unknown) => e)) as AppError;

      expect(JSON.stringify(unknown.getResponse())).toBe(
        JSON.stringify(notInvited.getResponse()),
      );
    });

    it('オーナー本人は招待行を確認せず通す', async () => {
      await useCase.execute(OWNER_ID, SHARE_ID, ITEM_KEY, dto());

      expect(access.findRecipient).not.toHaveBeenCalled();
      expect(updateShareItem.execute).toHaveBeenCalledWith(
        shareLink(),
        ITEM_KEY,
        dto(),
      );
    });

    it('招待済みの受け取り側は ③〜⑧ を担う use case へ委譲する', async () => {
      const item = await useCase.execute(
        RECIPIENT_ID,
        SHARE_ID,
        ITEM_KEY,
        dto(),
      );

      expect(access.findRecipient).toHaveBeenCalledWith(SHARE_ID, RECIPIENT_ID);
      expect(updateShareItem.execute).toHaveBeenCalledWith(
        shareLink(),
        ITEM_KEY,
        dto(),
      );
      expect(item).toEqual({ item_key: ITEM_KEY });
    });

    it('hidden な招待でも編集できる（非表示は受信箱の表示制御だけ）', async () => {
      access.findRecipient.mockResolvedValue({
        ...recipientRow(),
        hiddenAt: new Date('2026-08-01T12:00:00.000Z'),
      });

      await expect(
        useCase.execute(RECIPIENT_ID, SHARE_ID, ITEM_KEY, dto()),
      ).resolves.toEqual({ item_key: ITEM_KEY });
    });
  });

  it('③ 以降の判定は委譲先が投げた AppError をそのまま伝播する', async () => {
    updateShareItem.execute.mockRejectedValue(
      new AppError(ErrorCode.FORBIDDEN, 'share item is not editable'),
    );

    await expect(
      useCase.execute(RECIPIENT_ID, SHARE_ID, ITEM_KEY, dto()),
    ).rejects.toMatchObject({ code: ErrorCode.FORBIDDEN });
  });
});
