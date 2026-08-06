import { Module } from '@nestjs/common';
import { IdentitiesController } from './identities.controller';
import { IdentitiesService } from './identities.service';

/**
 * IdentitiesService は memberships (T4) / tours・events・applications (T5) が
 * assertOwned() を再利用するため export する。
 */
@Module({
  controllers: [IdentitiesController],
  providers: [IdentitiesService],
  exports: [IdentitiesService],
})
export class IdentitiesModule {}
