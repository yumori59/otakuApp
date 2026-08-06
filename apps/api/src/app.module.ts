import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { APP_GUARD, APP_INTERCEPTOR } from '@nestjs/core';
import { JwtModule } from '@nestjs/jwt';
import { ThrottlerModule } from '@nestjs/throttler';
import { ApplicationsModule } from './applications/applications.module';
import { AuthModule } from './auth/auth.module';
import { BillingModule } from './billing/billing.module';
import { JwtAuthGuard } from './common/guards/jwt-auth.guard';
import { RequestIdInterceptor } from './common/interceptors/request-id.interceptor';
import { THROTTLER_CONFIG } from './common/throttling/throttler-config';
import { EntitlementsModule } from './entitlements/entitlements.module';
import { EventsModule } from './events/events.module';
import { HealthModule } from './health/health.module';
import { HomeModule } from './home/home.module';
import { IdentitiesModule } from './identities/identities.module';
import { MailModule } from './mail/mail.module';
import { MeModule } from './me/me.module';
import { MembershipsModule } from './memberships/memberships.module';
import { PrismaModule } from './prisma/prisma.module';
import { PublicModule } from './public/public.module';
import { SharesModule } from './shares/shares.module';
import { StatsModule } from './stats/stats.module';
import { SyncModule } from './sync/sync.module';
import { ToursModule } from './tours/tours.module';

@Module({
  imports: [
    ConfigModule.forRoot({ isGlobal: true }),
    JwtModule.register({ global: true }),
    // 名前付き throttler の定義のみ。APP_GUARD としてのグローバル適用はしない
    // （全ルートに副作用を出さないため。適用は各コントローラで throttle-route.decorators を使う）。
    ThrottlerModule.forRoot(THROTTLER_CONFIG),
    MailModule,
    PrismaModule,
    EntitlementsModule,
    HealthModule,
    AuthModule,
    MeModule,
    IdentitiesModule,
    MembershipsModule,
    ToursModule,
    EventsModule,
    ApplicationsModule,
    SharesModule,
    PublicModule,
    HomeModule,
    StatsModule,
    SyncModule,
    BillingModule,
  ],
  providers: [
    { provide: APP_INTERCEPTOR, useClass: RequestIdInterceptor },
    // 既定で全ルート認証必須。公開ルートは @Public() を付ける（BE-4）
    { provide: APP_GUARD, useClass: JwtAuthGuard },
  ],
})
export class AppModule {}
