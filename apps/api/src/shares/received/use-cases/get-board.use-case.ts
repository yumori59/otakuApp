import { Injectable } from '@nestjs/common';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { ResolveShareUseCase } from '../../board/use-cases/resolve-share.use-case';
import { PublicSharePayload } from '../../board/public-share.presenter';
import { isShareActive } from '../../share-validity';
import { ReceivedInboxOwner } from '../received-share.presenter';
import { ShareRecipientAccessService } from '../share-recipient-access.service';

export type ReceivedBoardPayload = PublicSharePayload & {
  share_id: string;
  owner: ReceivedInboxOwner;
};

/**
 * `GET /v1/shares/received/:id`（api-contract-delta.md §4.2）。
 *
 * 判定順序:
 * ① :id が存在しない → 404 SHARE_INVALID
 * ② 失効 / 期限切れ → 404 SHARE_INVALID
 * ③ 呼び出し元がオーナー → 通す
 * ④ share_recipients に自分が無い → 404 SHARE_INVALID（403 にしない）
 * ⑤ ペイロード組み立て（ResolveShareUseCase に委譲。マスキングは再実装しない — NFR-7）
 */
@Injectable()
export class GetBoardUseCase {
  constructor(
    private readonly access: ShareRecipientAccessService,
    private readonly resolveShare: ResolveShareUseCase,
  ) {}

  async execute(userId: string, shareId: string): Promise<ReceivedBoardPayload> {
    const now = new Date();
    const link = await this.access.findLinkById(shareId);
    if (!link || !isShareActive(link, now)) {
      throw shareInvalid();
    }

    const isOwner = link.ownerId === userId;
    if (!isOwner) {
      const recipient = await this.access.findRecipient(shareId, userId);
      if (!recipient) throw shareInvalid();
    }

    const payload = await this.resolveShare.execute(link);

    // オーナー閲覧では share_recipients.last_viewed_at を更新しない（招待経由だけ計上）。
    if (!isOwner) {
      await this.access.markViewed(shareId, userId, now);
    }

    const ownerProfile = await this.access.findOwnerProfile(link.ownerId);
    return {
      ...payload,
      share_id: link.id,
      owner: {
        account_id: ownerProfile?.accountId ?? null,
        display_name: ownerProfile?.displayName ?? null,
      },
    };
  }
}

function shareInvalid(): AppError {
  return new AppError(ErrorCode.SHARE_INVALID, 'share link is invalid');
}
