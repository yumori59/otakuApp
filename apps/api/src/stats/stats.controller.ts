import { Controller, Get } from '@nestjs/common';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { StatsService } from './stats.service';

/** api-contract.md §3.5 `GET /v1/stats/identities`。認証必須 (BE-4)。 */
@Controller('stats')
export class StatsController {
  constructor(private readonly stats: StatsService) {}

  @Get('identities')
  getIdentityStats(@CurrentUser() userId: string) {
    return this.stats.getIdentityStats(userId);
  }
}
