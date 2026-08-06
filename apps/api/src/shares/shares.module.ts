import { Module } from '@nestjs/common';
import { ToursModule } from '../tours/tours.module';
import { SharesController } from './shares.controller';
import { SharesService } from './shares.service';
import { CreateShareUseCase } from './use-cases/create-share.use-case';

/**
 * api-contract.md §8 の認証必須 API (/v1/shares)。
 * SharesService は public (`/public/shares/:token`) がトークン解決に再利用するため export する。
 * PrismaModule / EntitlementsModule は @Global なので import 不要。
 */
@Module({
  imports: [ToursModule],
  controllers: [SharesController],
  providers: [SharesService, CreateShareUseCase],
  exports: [SharesService],
})
export class SharesModule {}
