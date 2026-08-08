import { Injectable } from '@nestjs/common';
import {
  ReceivedInboxItem,
  toReceivedInboxItem,
} from '../received-share.presenter';
import { ShareRecipientAccessService } from '../share-recipient-access.service';

/**
 * `GET /v1/shares/received`（api-contract-delta.md §4.1）。
 * 絞り込み・並びは ShareRecipientAccessService.listInboxRows に集約。
 */
@Injectable()
export class ListInboxUseCase {
  constructor(private readonly access: ShareRecipientAccessService) {}

  async execute(userId: string): Promise<ReceivedInboxItem[]> {
    const now = new Date();
    const rows = await this.access.listInboxRows(userId, now);

    const tourIds = rows
      .filter((row) => row.shareLink.scopeType === 'tour' && row.shareLink.scopeId)
      .map((row) => row.shareLink.scopeId as string);
    const tourNames = await this.access.resolveTourNames(tourIds);

    return rows.map((row) => toReceivedInboxItem(row, tourNames));
  }
}
