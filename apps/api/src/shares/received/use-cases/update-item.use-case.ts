import { Injectable } from '@nestjs/common';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { UpdateShareItemDto } from '../../board/dto/update-share-item.dto';
import { TourShareWriteItem } from '../../board/public-share.presenter';
import { UpdateShareItemUseCase } from '../../board/use-cases/update-share-item.use-case';
import { isShareActive } from '../../share-validity';
import { ShareRecipientAccessService } from '../share-recipient-access.service';

/**
 * `PATCH /v1/shares/received/:id/items/:item_key`（api-contract-delta.md §4.3）。
 *
 * 判定順序（契約・この順を変えない — AC-SI-29）:
 * ① `:id` 未知 / 失効 / 期限切れ                → 404 SHARE_INVALID
 * ② オーナー本人でなく、かつ招待リストに無い     → 404 SHARE_INVALID
 * ③〜⑧（permission / scope_type / ボディ / item_key / editable / rev）
 *    → `UpdateShareItemUseCase`（`shares/board/`）に委譲
 *
 * **② は ③ より前**。逆にすると非招待者が read リンクで 403 を受け取り、
 * 「そのリンクは実在する」ことが分かってしまう（plan.md D10）。
 * 未知の `:id` と非招待の `:id` はエラー本文まで同一にする。
 *
 * 招待行の `hidden_at` は受信箱の表示制御でしかないので、非表示でも編集はできる。
 * 閲覧（`get-board.use-case.ts`）と違い `last_viewed_at` は更新しない
 * （編集は閲覧ではない。副作用は `share_links.edit_count` のみ — AC-SW-20 / AC-SW-21）。
 */
@Injectable()
export class UpdateItemUseCase {
  constructor(
    private readonly access: ShareRecipientAccessService,
    private readonly updateShareItem: UpdateShareItemUseCase,
  ) {}

  async execute(
    userId: string,
    shareId: string,
    itemKey: string,
    dto: UpdateShareItemDto,
  ): Promise<TourShareWriteItem> {
    // ① :id の有効性（token を経由しない id 起点の解決）
    const link = await this.access.findLinkById(shareId);
    if (!link || !isShareActive(link, new Date())) throw shareInvalid();

    // ② 招待判定（**permission 判定より前** — AC-SI-29）
    if (link.ownerId !== userId) {
      const recipient = await this.access.findRecipient(shareId, userId);
      if (!recipient) throw shareInvalid();
    }

    // ③〜⑧
    return this.updateShareItem.execute(link, itemKey, dto);
  }
}

/** 存在有無・オーナー・permission を message からも漏らさない（GET と同一文言）。 */
function shareInvalid(): AppError {
  return new AppError(ErrorCode.SHARE_INVALID, 'share link is invalid');
}
