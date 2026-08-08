import { applyDecorators, UseGuards } from '@nestjs/common';
import { SkipThrottle } from '@nestjs/throttler';
import { EmailThrottlerGuard } from './email-throttler.guard';
import {
  ALL_THROTTLER_NAMES,
  THROTTLER_NAME,
  ThrottlerName,
} from './throttler-config';
import { UserShareThrottlerGuard } from './user-share-throttler.guard';
import { UserThrottlerGuard } from './user-throttler.guard';

/**
 * `ThrottlerModule.forRoot(THROTTLER_CONFIG)` は 1 つの guard 実行あたり
 * 登録済みの全 named throttler をチェックする（@nestjs/throttler の既定動作）。
 * ルートごとに 1 つの named throttler だけを効かせたいので、対象以外は
 * `@SkipThrottle` で明示的に skip する。
 */
function skipAllExcept(name: ThrottlerName): Record<string, boolean> {
  const skip: Record<string, boolean> = {};
  for (const candidate of ALL_THROTTLER_NAMES) {
    if (candidate !== name) skip[candidate] = true;
  }
  return skip;
}

/** `POST /v1/auth/register` / `POST /v1/auth/login` に適用（正規化 email・10 回/5 分）。 */
export function ThrottleAuthEmail(): ClassDecorator & MethodDecorator {
  return applyDecorators(
    UseGuards(EmailThrottlerGuard),
    SkipThrottle(skipAllExcept(THROTTLER_NAME.AUTH_EMAIL)),
  );
}

/** `POST /v1/auth/password` に適用（userId・10 回/5 分）。 */
export function ThrottleAuthUser(): ClassDecorator & MethodDecorator {
  return applyDecorators(
    UseGuards(UserThrottlerGuard),
    SkipThrottle(skipAllExcept(THROTTLER_NAME.AUTH_USER)),
  );
}

/** `POST /v1/auth/password/reset-request` に適用（正規化 email・3 回/15 分）。 */
export function ThrottleResetRequest(): ClassDecorator & MethodDecorator {
  return applyDecorators(
    UseGuards(EmailThrottlerGuard),
    SkipThrottle(skipAllExcept(THROTTLER_NAME.RESET_REQUEST)),
  );
}

/** `POST /v1/auth/password/reset` に適用（正規化 email・10 回/15 分）。 */
export function ThrottleResetSubmit(): ClassDecorator & MethodDecorator {
  return applyDecorators(
    UseGuards(EmailThrottlerGuard),
    SkipThrottle(skipAllExcept(THROTTLER_NAME.RESET_SUBMIT)),
  );
}

/**
 * `PATCH /v1/shares/received/:id/items/:item_key` に適用
 * （userId + share_id・60 回/分。api-contract-delta.md §0.3）。
 */
export function ThrottleShareWrite(): ClassDecorator & MethodDecorator {
  return applyDecorators(
    UseGuards(UserShareThrottlerGuard),
    SkipThrottle(skipAllExcept(THROTTLER_NAME.SHARE_WRITE)),
  );
}
