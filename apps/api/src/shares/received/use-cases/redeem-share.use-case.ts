import { Injectable } from '@nestjs/common';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { SharesService } from '../../shares.service';
import { isShareActive } from '../../share-validity';
import { ShareRecipientAccessService } from '../share-recipient-access.service';

export interface RedeemShareResult {
  share_id: string;
}

/**
 * `POST /v1/shares/received/redeem`（api-contract-delta.md §4.4）。
 * ディープリンクの入口。副作用なし（view_count は増やさない。閲覧計上は GetBoardUseCase）。
 *
 * | 条件 | 応答 |
 * |---|---|
 * | 未知 / 失効 / 期限切れトークン | 404 SHARE_INVALID（3 者を区別しない） |
 * | 有効トークン + 招待済み or オーナー本人 | 200 {share_id} |
 * | 有効トークン + 招待されていない | 403 SHARE_NOT_INVITED（本契約で唯一「存在を confirm する」応答） |
 */
@Injectable()
export class RedeemShareUseCase {
  constructor(
    private readonly shares: SharesService,
    private readonly access: ShareRecipientAccessService,
  ) {}

  async execute(userId: string, token: string): Promise<RedeemShareResult> {
    const now = new Date();
    const link = await this.shares.findByToken(token);
    if (!link || !isShareActive(link, now)) {
      throw shareInvalid();
    }

    if (link.ownerId === userId) {
      return { share_id: link.id };
    }

    const recipient = await this.access.findRecipient(link.id, userId);
    if (!recipient) {
      throw new AppError(
        ErrorCode.SHARE_NOT_INVITED,
        'account is not invited to this share',
      );
    }

    return { share_id: link.id };
  }
}

function shareInvalid(): AppError {
  return new AppError(ErrorCode.SHARE_INVALID, 'share link is invalid');
}
