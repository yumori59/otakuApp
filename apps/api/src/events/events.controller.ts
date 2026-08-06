import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Query,
} from '@nestjs/common';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { ListEventsQueryDto } from './dto/list-events-query.dto';
import { UpdateEventDto } from './dto/update-event.dto';
import { EventsService } from './events.service';

/**
 * api-contract.md §6 Events。全エンドポイント認証必須 (BE-4)。
 * `POST /v1/events` は提供しない（作成経路は applications の find-or-create — D9）。
 */
@Controller('events')
export class EventsController {
  constructor(private readonly events: EventsService) {}

  @Get()
  async list(
    @CurrentUser() userId: string,
    @Query() query: ListEventsQueryDto,
  ) {
    return { items: await this.events.list(userId, query.tour_id) };
  }

  @Get(':id')
  get(@CurrentUser() userId: string, @Param('id') id: string) {
    return this.events.get(userId, id);
  }

  @Patch(':id')
  update(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body() dto: UpdateEventDto,
  ) {
    return this.events.update(userId, id, dto);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  async remove(@CurrentUser() userId: string, @Param('id') id: string) {
    await this.events.remove(userId, id);
  }
}
