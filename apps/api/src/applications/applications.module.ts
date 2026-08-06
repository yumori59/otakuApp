import { Module } from '@nestjs/common';
import { EventsModule } from '../events/events.module';
import { IdentitiesModule } from '../identities/identities.module';
import { ToursModule } from '../tours/tours.module';
import { ApplicationsController } from './applications.controller';
import { ApplicationsService } from './applications.service';
import { CreateApplicationUseCase } from './use-cases/create-application.use-case';
import { UpdateApplicationUseCase } from './use-cases/update-application.use-case';

/**
 * tour find-or-create / event upsert / identity 所有検証を
 * それぞれの Service に委譲するため 3 モジュールを import する（ADR-009）。
 */
@Module({
  imports: [ToursModule, EventsModule, IdentitiesModule],
  controllers: [ApplicationsController],
  providers: [
    ApplicationsService,
    CreateApplicationUseCase,
    UpdateApplicationUseCase,
  ],
  exports: [ApplicationsService],
})
export class ApplicationsModule {}
