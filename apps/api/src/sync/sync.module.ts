import { Module } from '@nestjs/common';
import { IdentitiesModule } from '../identities/identities.module';
import { SyncController } from './sync.controller';
import { SyncService } from './sync.service';

@Module({
  imports: [IdentitiesModule],
  controllers: [SyncController],
  providers: [SyncService],
})
export class SyncModule {}
