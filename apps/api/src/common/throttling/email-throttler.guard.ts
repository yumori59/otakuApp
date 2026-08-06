import { Injectable } from '@nestjs/common';
import { ThrottlerGuard } from '@nestjs/throttler';
import { emailTracker } from './trackers';

/**
 * body.email を tracker にする throttler guard。
 * `auth-email` / `reset-request` / `reset-submit` の 3 経路で共有する
 * （どれも「同じメールでの試行回数」を制限したいだけで tracker は共通）。
 * 実際に有効になる named throttler は各ルートの `@SkipThrottle` で 1 つに絞る。
 */
@Injectable()
export class EmailThrottlerGuard extends ThrottlerGuard {
  protected getTracker(req: Record<string, unknown>): Promise<string> {
    return Promise.resolve(emailTracker(req));
  }
}
