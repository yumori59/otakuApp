import { CanActivate, ExecutionContext, Inject, Injectable } from '@nestjs/common';
import { ThrottlerException, ThrottlerStorage } from '@nestjs/throttler';
import { userTracker } from '../../common/throttling/trackers';

/** 30 回/分・userId 単位（api-contract-delta.md §0.3）。 */
const REDEEM_LIMIT = 30;
const REDEEM_TTL_MS = 60_000;

/**
 * `POST /v1/shares/received/redeem` 専用のレート制限。
 *
 * `common/throttling/**` は T2 の所有物のため名前付き throttler を追加登録できず
 * （並列実装のファイル分担上ここを編集できない）、`ThrottlerModule.forRoot` が
 * 全モジュール共通で export している `ThrottlerStorage`（@Global）を直接使う。
 * tracker は既存の `userTracker`（`req.user.id`。JwtAuthGuard 済み前提）を再利用する。
 */
@Injectable()
export class RedeemThrottlerGuard implements CanActivate {
  constructor(
    @Inject(ThrottlerStorage) private readonly storage: ThrottlerStorage,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const req = context.switchToHttp().getRequest<Record<string, unknown>>();
    const tracker = userTracker(req);
    const key = `share-redeem:${tracker}`;

    const { isBlocked } = await this.storage.increment(
      key,
      REDEEM_TTL_MS,
      REDEEM_LIMIT,
      REDEEM_TTL_MS,
      'share-redeem',
    );
    if (isBlocked) {
      throw new ThrottlerException();
    }
    return true;
  }
}
