import { Injectable } from '@nestjs/common';
import { ThrottlerGuard } from '@nestjs/throttler';
import { tokenTracker } from './trackers';

/** req.params.token を tracker にする throttler guard。`share-write` 用。 */
@Injectable()
export class TokenThrottlerGuard extends ThrottlerGuard {
  protected getTracker(req: Record<string, unknown>): Promise<string> {
    return Promise.resolve(tokenTracker(req));
  }
}
