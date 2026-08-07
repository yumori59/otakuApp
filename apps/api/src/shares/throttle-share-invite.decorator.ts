import { applyDecorators, UseGuards } from '@nestjs/common';
import { SkipThrottle, Throttle } from '@nestjs/throttler';
import {
  ALL_THROTTLER_NAMES,
  THROTTLER_NAME,
} from '../common/throttling/throttler-config';
import { userTracker } from '../common/throttling/trackers';
import { UserThrottlerGuard } from '../common/throttling/user-throttler.guard';

const MINUTE_MS = 60_000;
/** ACC-ID 列挙防止のレート制限（api-contract-delta.md §0.3）。userId 単位・30 回/分。 */
const SHARE_INVITE_LIMIT = 30;

/**
 * `POST /v1/shares` / `POST /v1/shares/:id/recipients` に適用する（api-contract-delta.md §0.3）。
 *
 * `common/throttling/*` に新しい named throttler を追加せず、既に登録済みの `share-write`
 * バケットを per-route の `@Throttle()` で上書きして流用する。`common/throttling/*` は
 * このタスク（T3）の所有ファイルではなく、他タスクと並列実行中のため編集しない
 * （`.claude/rules/03-parallel-development.md`）。
 * tracker を `userTracker`（userId のみ）に差し替えるため、board 側の
 * `ThrottleShareWrite`（userId + shareId）とはカウントの名前空間が実質的に分かれる。
 */
export function ThrottleShareInvite(): ClassDecorator & MethodDecorator {
  const skip: Record<string, boolean> = {};
  for (const name of ALL_THROTTLER_NAMES) {
    if (name !== THROTTLER_NAME.SHARE_WRITE) skip[name] = true;
  }

  return applyDecorators(
    UseGuards(UserThrottlerGuard),
    SkipThrottle(skip),
    Throttle({
      [THROTTLER_NAME.SHARE_WRITE]: {
        limit: SHARE_INVITE_LIMIT,
        ttl: MINUTE_MS,
        getTracker: (req: Record<string, unknown>) =>
          Promise.resolve(userTracker(req)),
      },
    }),
  );
}
