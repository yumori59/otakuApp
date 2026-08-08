import { Injectable } from '@nestjs/common';
import { ThrottlerGuard } from '@nestjs/throttler';
import { userShareTracker } from './trackers';

/**
 * `req.user.id` + `req.params.id`（共有 ID）を tracker にする throttler guard。
 * `share-write` 用（招待制化により token が req に現れなくなったため `TokenThrottlerGuard` から置き換え）。
 */
@Injectable()
export class UserShareThrottlerGuard extends ThrottlerGuard {
  protected getTracker(req: Record<string, unknown>): Promise<string> {
    return Promise.resolve(userShareTracker(req));
  }
}
