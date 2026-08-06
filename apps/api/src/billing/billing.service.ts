import { Injectable, Logger, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { isUUID } from 'class-validator';
import { PrismaService } from '../prisma/prisma.service';
import { RevenueCatWebhookDto } from './dto/revenuecat-webhook.dto';

const PLUS_EVENTS = new Set(['INITIAL_PURCHASE', 'RENEWAL', 'UNCANCELLATION']);
const FREE_EVENTS = new Set(['EXPIRATION', 'REFUND', 'SUBSCRIPTION_PAUSED']);

/**
 * RevenueCat Webhook → entitlements 更新 (docs/04 §3.8, docs/07 §9.2)。
 * entitlements の書き込みは本モジュールのみ (ADR-002)。
 */
@Injectable()
export class BillingService {
  private readonly logger = new Logger(BillingService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly config: ConfigService,
  ) {}

  assertAuthorized(authorizationHeader: string | undefined): void {
    const secret = this.config.get<string>('REVENUECAT_WEBHOOK_SECRET');
    if (!secret) {
      throw new UnauthorizedException('webhook secret not configured');
    }
    if (authorizationHeader !== `Bearer ${secret}`) {
      throw new UnauthorizedException('invalid webhook authorization');
    }
  }

  async handleWebhook(dto: RevenueCatWebhookDto): Promise<void> {
    const { event } = dto;
    const userId = event.app_user_id;
    const eventType = event.type;

    // 未知・未登録ユーザーは 200 no-op（RevenueCat の無限リトライを避ける）
    if (!isUUID(userId)) {
      this.logger.warn(`ignoring webhook: invalid app_user_id type=${eventType}`);
      return;
    }

    const user = await this.prisma.user.findUnique({
      where: { id: userId },
      select: { id: true },
    });
    if (!user) {
      this.logger.warn(
        `ignoring webhook: user not found userId=${userId} type=${eventType}`,
      );
      return;
    }

    if (PLUS_EVENTS.has(eventType)) {
      await this.prisma.entitlement.upsert({
        where: { userId },
        create: {
          userId,
          plan: 'plus',
          productId: event.product_id ?? null,
          expiresAt: msToDate(event.expiration_at_ms),
          inGracePeriod: false,
        },
        update: {
          plan: 'plus',
          productId: event.product_id ?? undefined,
          expiresAt: msToDate(event.expiration_at_ms),
          inGracePeriod: false,
        },
      });
      return;
    }

    if (eventType === 'BILLING_ISSUE') {
      await this.prisma.entitlement.upsert({
        where: { userId },
        create: {
          userId,
          plan: 'plus',
          inGracePeriod: true,
        },
        update: {
          inGracePeriod: true,
        },
      });
      return;
    }

    if (FREE_EVENTS.has(eventType)) {
      await this.prisma.entitlement.upsert({
        where: { userId },
        create: {
          userId,
          plan: 'free',
          inGracePeriod: false,
        },
        update: {
          plan: 'free',
          inGracePeriod: false,
          expiresAt: null,
        },
      });
      return;
    }

    // CANCELLATION / PRODUCT_CHANGE / TRANSFER 等 — plan は触らない（docs/07 §9.2）
    if (eventType === 'PRODUCT_CHANGE' && event.product_id) {
      await this.prisma.entitlement.upsert({
        where: { userId },
        create: {
          userId,
          productId: event.product_id,
        },
        update: {
          productId: event.product_id,
        },
      });
    }
  }
}

function msToDate(ms: number | undefined): Date | null {
  if (ms === undefined || ms === null) return null;
  return new Date(ms);
}
