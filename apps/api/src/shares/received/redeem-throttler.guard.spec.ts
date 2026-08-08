import { ExecutionContext } from '@nestjs/common';
import { ThrottlerException, ThrottlerStorage } from '@nestjs/throttler';
import { RedeemThrottlerGuard } from './redeem-throttler.guard';

function contextFor(userId: string | undefined): ExecutionContext {
  const req = { user: userId ? { id: userId } : undefined };
  return {
    switchToHttp: () => ({ getRequest: () => req }),
  } as unknown as ExecutionContext;
}

describe('RedeemThrottlerGuard', () => {
  let storage: { increment: jest.Mock };
  let guard: RedeemThrottlerGuard;

  beforeEach(() => {
    storage = {
      increment: jest.fn().mockResolvedValue({
        totalHits: 1,
        timeToExpire: 60,
        isBlocked: false,
        timeToBlockExpire: 0,
      }),
    };
    guard = new RedeemThrottlerGuard(storage as unknown as ThrottlerStorage);
  });

  it('30 回/分・userId 単位で increment を呼ぶ', async () => {
    await guard.canActivate(contextFor('user-1'));

    expect(storage.increment).toHaveBeenCalledWith(
      'share-redeem:user-1',
      60_000,
      30,
      60_000,
      'share-redeem',
    );
  });

  it('上限内なら true を返す', async () => {
    await expect(guard.canActivate(contextFor('user-1'))).resolves.toBe(true);
  });

  it('ブロック判定なら ThrottlerException（429）を投げる', async () => {
    storage.increment.mockResolvedValue({
      totalHits: 31,
      timeToExpire: 60,
      isBlocked: true,
      timeToBlockExpire: 60,
    });

    await expect(guard.canActivate(contextFor('user-1'))).rejects.toBeInstanceOf(
      ThrottlerException,
    );
  });

  it('userId ごとにキーを分ける', async () => {
    await guard.canActivate(contextFor('user-1'));
    await guard.canActivate(contextFor('user-2'));

    expect(storage.increment).toHaveBeenNthCalledWith(
      1,
      'share-redeem:user-1',
      60_000,
      30,
      60_000,
      'share-redeem',
    );
    expect(storage.increment).toHaveBeenNthCalledWith(
      2,
      'share-redeem:user-2',
      60_000,
      30,
      60_000,
      'share-redeem',
    );
  });
});
