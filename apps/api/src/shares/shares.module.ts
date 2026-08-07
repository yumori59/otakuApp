import { Module } from '@nestjs/common';
import { ToursModule } from '../tours/tours.module';
import { ShareRecipientsService } from './share-recipients.service';
import { SharesController } from './shares.controller';
import { SharesService } from './shares.service';
import { AddRecipientsUseCase } from './use-cases/add-recipients.use-case';
import { CreateShareUseCase } from './use-cases/create-share.use-case';
import { RemoveRecipientUseCase } from './use-cases/remove-recipient.use-case';

/**
 * api-contract-delta.md §1〜§3 の認証必須 API (/v1/shares)。
 * SharesService / ShareRecipientsService は `shares/board` `shares/received`（招待判定・board 組み立て）
 * が再利用するため export する。PrismaModule / EntitlementsModule は @Global なので import 不要。
 */
@Module({
  imports: [ToursModule],
  controllers: [SharesController],
  providers: [
    SharesService,
    ShareRecipientsService,
    CreateShareUseCase,
    AddRecipientsUseCase,
    RemoveRecipientUseCase,
  ],
  exports: [SharesService, ShareRecipientsService],
})
export class SharesModule {}
