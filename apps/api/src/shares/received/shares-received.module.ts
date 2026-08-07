import { Module } from '@nestjs/common';
import { ShareBoardModule } from '../board/share-board.module';
import { SharesModule } from '../shares.module';
import { SharesReceivedController } from './shares-received.controller';
import { ShareRecipientAccessService } from './share-recipient-access.service';
import { GetBoardUseCase } from './use-cases/get-board.use-case';
import { ListInboxUseCase } from './use-cases/list-inbox.use-case';
import { RedeemShareUseCase } from './use-cases/redeem-share.use-case';
import { SetHiddenUseCase } from './use-cases/set-hidden.use-case';

/**
 * 受け取り側の共有 API（api-contract-delta.md §4 / share-account-invites）。
 * `GET /v1/shares/received` / `GET /v1/shares/received/:id` /
 * `POST /v1/shares/received/redeem` / `POST|DELETE /v1/shares/received/:id/hide`。
 *
 * `PATCH /v1/shares/received/:id/items/:item_key` は T5 がこの上に足す。
 * **全ルート Bearer 必須。`@Public()` を付けない**（BE-4。JwtAuthGuard は APP_GUARD 既定）。
 * `SharesModule` は `SharesService.findByToken`（redeem 用）、
 * `ShareBoardModule` は `ResolveShareUseCase`（get-board 用）を export している。
 */
@Module({
  imports: [SharesModule, ShareBoardModule],
  controllers: [SharesReceivedController],
  providers: [
    ShareRecipientAccessService,
    ListInboxUseCase,
    GetBoardUseCase,
    RedeemShareUseCase,
    SetHiddenUseCase,
  ],
  exports: [ShareRecipientAccessService],
})
export class SharesReceivedModule {}
