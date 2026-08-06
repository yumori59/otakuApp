import { Module } from '@nestjs/common';
import { IdentitiesModule } from '../identities/identities.module';
import { SharesModule } from '../shares/shares.module';
import { ToursModule } from '../tours/tours.module';
import { IdentitySummaryService } from './identity-summary.service';
import { PublicController } from './public.controller';
import { SharedApplicationsService } from './shared-applications.service';
import { ResolveShareUseCase } from './use-cases/resolve-share.use-case';
import { UpdateShareItemUseCase } from './use-cases/update-share-item.use-case';

/**
 * 認証不要の共有閲覧 (`GET /public/shares/:token`) と
 * 共有先による軽量編集 (`PATCH /public/shares/:token/items/:item_key`)。
 * TourMatrixService (T5) と IdentitiesService (T3) を再利用し、
 * マスキングだけを public-share.presenter.ts で足す。
 * PrismaModule / EntitlementsModule は @Global なので import 不要。
 */
@Module({
  imports: [SharesModule, ToursModule, IdentitiesModule],
  controllers: [PublicController],
  providers: [
    ResolveShareUseCase,
    UpdateShareItemUseCase,
    IdentitySummaryService,
    SharedApplicationsService,
  ],
})
export class PublicModule {}
