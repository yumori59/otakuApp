import { Body, Controller, Headers, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { Public } from '../common/decorators/public.decorator';
import { BillingService } from './billing.service';
import { RevenueCatWebhookDto } from './dto/revenuecat-webhook.dto';

/**
 * api-contract.md §3.8 RevenueCat Webhook。
 * `@Public()` + Bearer シークレット検証 (BE-4)。
 */
@Controller('webhooks')
export class BillingController {
  constructor(private readonly billing: BillingService) {}

  @Public()
  @Post('revenuecat')
  @HttpCode(HttpStatus.OK)
  async revenueCat(
    @Headers('authorization') authorization: string | undefined,
    @Body() dto: RevenueCatWebhookDto,
  ): Promise<{ ok: true }> {
    this.billing.assertAuthorized(authorization);
    await this.billing.handleWebhook(dto);
    return { ok: true };
  }
}
