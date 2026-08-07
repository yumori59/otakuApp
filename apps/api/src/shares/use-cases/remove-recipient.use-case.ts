import { Injectable } from '@nestjs/common';
import { ShareRecipientsService } from '../share-recipients.service';
import { SharesService } from '../shares.service';

/**
 * DELETE /v1/shares/:id/recipients/:account_id（api-contract-delta.md §3.2）。
 * 204。存在しない ACC-ID でも冪等に 204（AC-SI-09）。他人の `:id` は 404（BE-4 / AC-SI-10）。
 * 最後の 1 人を削除しても許可する（AC-SI-12。3.2 は失効/期限切れを 404 にする記載が無いため
 * 有効性は見ない — `POST /recipients` の 3.1 とは異なる）。
 */
@Injectable()
export class RemoveRecipientUseCase {
  constructor(
    private readonly shares: SharesService,
    private readonly shareRecipients: ShareRecipientsService,
  ) {}

  async execute(
    userId: string,
    shareId: string,
    accountId: string,
  ): Promise<void> {
    await this.shares.findOwned(userId, shareId);
    await this.shareRecipients.remove(shareId, accountId);
  }
}
