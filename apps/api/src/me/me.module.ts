import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { MeController } from './me.controller';
import { MeService } from './me.service';
import { DeleteMeUseCase } from './use-cases/delete-me.use-case';

/**
 * `GET/PATCH/DELETE /v1/me`。PrismaModule / EntitlementsModule は @Global のため
 * imports に列挙しなくても DI できる。
 * AuthModule は `PasswordHasher`（削除時の本人確認）を得るためだけに import する（D6）。
 */
@Module({
  imports: [AuthModule],
  controllers: [MeController],
  providers: [MeService, DeleteMeUseCase],
})
export class MeModule {}
