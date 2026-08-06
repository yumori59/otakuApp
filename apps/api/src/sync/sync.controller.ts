import { Body, Controller, Post } from '@nestjs/common';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { SyncPullDto, SyncPushDto } from './dto/sync.dto';
import { SyncService } from './sync.service';

/** api-contract.md §3.6 / §4 Sync。認証必須 (BE-4)。 */
@Controller('sync')
export class SyncController {
  constructor(private readonly sync: SyncService) {}

  @Post('pull')
  pull(@CurrentUser() userId: string, @Body() dto: SyncPullDto) {
    return this.sync.pull(userId, dto.cursor ?? null, dto.collections);
  }

  @Post('push')
  push(@CurrentUser() userId: string, @Body() dto: SyncPushDto) {
    return this.sync.push(userId, dto);
  }
}
