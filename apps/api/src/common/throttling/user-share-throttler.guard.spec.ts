import { UserShareThrottlerGuard } from './user-share-throttler.guard';

interface TestableGuard {
  getTracker(req: Record<string, unknown>): Promise<string>;
}

describe('UserShareThrottlerGuard', () => {
  it('AC-SI-05 getTracker は req.user.id と req.params.id を連結して返す', async () => {
    const guard = new UserShareThrottlerGuard(
      [] as never,
      {} as never,
      {} as never,
    ) as unknown as TestableGuard;

    await expect(
      guard.getTracker({ user: { id: 'user-1' }, params: { id: 'share-1' } }),
    ).resolves.toBe('user-1:share-1');
  });
});
