import { Injectable } from '@nestjs/common';
import { ThrottlerGuard } from '@nestjs/throttler';
import { userTracker } from './trackers';

/** req.user.id（JwtAuthGuard 済み）を tracker にする throttler guard。`auth-user` 用。 */
@Injectable()
export class UserThrottlerGuard extends ThrottlerGuard {
  protected getTracker(req: Record<string, unknown>): Promise<string> {
    return Promise.resolve(userTracker(req));
  }
}
