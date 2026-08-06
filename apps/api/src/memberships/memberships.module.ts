import { Module } from '@nestjs/common';
import { IdentitiesModule } from '../identities/identities.module';
import { MembershipsController } from './memberships.controller';
import { MembershipsService } from './memberships.service';

/** IdentitiesModule から IdentitiesService.assertOwned を再利用する（BE-4）。 */
@Module({
  imports: [IdentitiesModule],
  controllers: [MembershipsController],
  providers: [MembershipsService],
})
export class MembershipsModule {}
