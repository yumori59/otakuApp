import { UserThrottlerGuard } from './user-throttler.guard';

interface TestableGuard {
  getTracker(req: Record<string, unknown>): Promise<string>;
}

describe('UserThrottlerGuard', () => {
  it('AC-T0-05 getTracker は req.user.id を返す', async () => {
    const guard = new UserThrottlerGuard(
      [] as never,
      {} as never,
      {} as never,
    ) as unknown as TestableGuard;

    await expect(guard.getTracker({ user: { id: 'user-1' } })).resolves.toBe(
      'user-1',
    );
  });
});
