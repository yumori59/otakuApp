import { Global, Module } from '@nestjs/common';
import { EntitlementsService } from './entitlements.service';

/**
 * identities / shares / me から参照される読み取り専用モジュール。
 * 各モジュールが import 行を足さずに使えるよう @Global にしている。
 */
@Global()
@Module({
  providers: [EntitlementsService],
  exports: [EntitlementsService],
})
export class EntitlementsModule {}
