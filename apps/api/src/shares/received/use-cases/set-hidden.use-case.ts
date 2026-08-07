import { Injectable } from '@nestjs/common';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { ShareRecipientAccessService } from '../share-recipient-access.service';

/**
 * `POST|DELETE /v1/shares/received/:id/hide`（api-contract-delta.md §4.5）。
 * 冪等。招待されていない `:id`（オーナー本人を含む — 招待行が無いため）は 404 SHARE_INVALID。
 */
@Injectable()
export class SetHiddenUseCase {
  constructor(private readonly access: ShareRecipientAccessService) {}

  async execute(userId: string, shareId: string, hidden: boolean): Promise<void> {
    const updated = await this.access.setHidden(shareId, userId, hidden);
    if (!updated) {
      throw new AppError(ErrorCode.SHARE_INVALID, 'share link is invalid');
    }
  }
}
