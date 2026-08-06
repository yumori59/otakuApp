import { TokenThrottlerGuard } from './token-throttler.guard';

interface TestableGuard {
  getTracker(req: Record<string, unknown>): Promise<string>;
}

describe('TokenThrottlerGuard', () => {
  it('AC-T0-05 getTracker は req.params.token を返す', async () => {
    const guard = new TokenThrottlerGuard(
      [] as never,
      {} as never,
      {} as never,
    ) as unknown as TestableGuard;

    await expect(
      guard.getTracker({ params: { token: 'tok-1' } }),
    ).resolves.toBe('tok-1');
  });
});
