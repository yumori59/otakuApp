import { EmailThrottlerGuard } from './email-throttler.guard';

interface TestableGuard {
  getTracker(req: Record<string, unknown>): Promise<string>;
}

describe('EmailThrottlerGuard', () => {
  it('AC-T0-05 getTracker は body.email を trim().toLowerCase() して返す', async () => {
    const guard = new EmailThrottlerGuard(
      [] as never,
      {} as never,
      {} as never,
    ) as unknown as TestableGuard;

    await expect(
      guard.getTracker({ body: { email: '  Fan@Example.com ' } }),
    ).resolves.toBe('fan@example.com');
  });
});
