import { Controller, Get } from '@nestjs/common';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { HomeService } from './home.service';

/** api-contract.md §3.5 `GET /v1/home/summary`。認証必須 (BE-4)。 */
@Controller('home')
export class HomeController {
  constructor(private readonly home: HomeService) {}

  @Get('summary')
  getSummary(@CurrentUser() userId: string) {
    return this.home.getSummary(userId);
  }
}
