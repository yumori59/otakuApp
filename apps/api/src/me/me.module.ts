import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { AvatarImageProcessor } from './avatar/avatar-image.processor';
import { AvatarService } from './avatar/avatar.service';
import { AvatarStorage } from './avatar/avatar.storage';
import { GcsAvatarStorage } from './avatar/gcs-avatar.storage';
import { MeController } from './me.controller';
import { MeService } from './me.service';
import { DeleteAvatarUseCase } from './use-cases/delete-avatar.use-case';
import { DeleteMeUseCase } from './use-cases/delete-me.use-case';
import { UploadAvatarUseCase } from './use-cases/upload-avatar.use-case';

/**
 * `GET/PATCH/DELETE/PUT /v1/me`。PrismaModule / EntitlementsModule は @Global のため
 * imports に列挙しなくても DI できる。ConfigModule も @Global。
 * AuthModule は `PasswordHasher`（削除時の本人確認）を得るためだけに import する（D6）。
 */
@Module({
  imports: [AuthModule],
  controllers: [MeController],
  providers: [
    MeService,
    AvatarImageProcessor,
    { provide: AvatarStorage, useClass: GcsAvatarStorage },
    AvatarService,
    DeleteMeUseCase,
    UploadAvatarUseCase,
    DeleteAvatarUseCase,
  ],
})
export class MeModule {}
