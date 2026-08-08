import { Module } from '@nestjs/common';
import { IdentitiesModule } from '../../identities/identities.module';
import { ToursModule } from '../../tours/tours.module';
import { SharesModule } from '../shares.module';
import { IdentitySummaryService } from './identity-summary.service';
import { SharedApplicationsService } from './shared-applications.service';
import { ResolveShareUseCase } from './use-cases/resolve-share.use-case';
import { UpdateShareItemUseCase } from './use-cases/update-share-item.use-case';

/**
 * 共有 board のペイロード組み立て・マスキング（share-account-invites）。
 *
 * 旧 `PublicModule`（`GET /public/shares/:token` / `PATCH /public/shares/:token/items/:item_key`、
 * 認証不要）の中身のうち、公開経路とは無関係な「ペイロード組み立てとマスキングの中核」だけを
 * 移設したもの（api-contract-delta.md §5）。中身・振る舞いは変えていない。
 *
 * コントローラは持たない（ルートは `shares/received/` 側が持つ）。
 * `ResolveShareUseCase` / `UpdateShareItemUseCase` を `shares/received/` から使えるよう export する。
 * PrismaModule / EntitlementsModule は @Global なので import 不要。
 */
@Module({
  imports: [SharesModule, ToursModule, IdentitiesModule],
  providers: [
    ResolveShareUseCase,
    UpdateShareItemUseCase,
    IdentitySummaryService,
    SharedApplicationsService,
  ],
  exports: [ResolveShareUseCase, UpdateShareItemUseCase],
})
export class ShareBoardModule {}
