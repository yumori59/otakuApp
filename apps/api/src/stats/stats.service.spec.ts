import { PrismaService } from '../prisma/prisma.service';
import { StatsService } from './stats.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';

describe('StatsService', () => {
  let prisma: { application: { findMany: jest.Mock } };
  let service: StatsService;

  beforeEach(() => {
    prisma = {
      application: {
        findMany: jest.fn().mockResolvedValue([
          {
            id: 'app-1',
            status: 'won',
            repIdentityId: 'id-a',
            companions: [{ identityId: 'id-b' }],
          },
          {
            id: 'app-2',
            status: 'lost',
            repIdentityId: 'id-a',
            companions: [],
          },
          {
            id: 'app-3',
            status: 'applied',
            repIdentityId: 'id-b',
            companions: [],
          },
          {
            id: 'app-4',
            status: 'won',
            repIdentityId: 'id-a',
            companions: [{ identityId: 'id-a' }],
          },
        ]),
      },
    };
    service = new StatsService(prisma as unknown as PrismaService);
  });

  it('v_identity_stats 相当 — union 重複排除と win_rate_percent', async () => {
    const result = await service.getIdentityStats(USER_ID);

    const a = result.items.find((i) => i.identity_id === 'id-a');
    expect(a).toMatchObject({
      application_count: 3,
      won_count: 2,
      lost_count: 1,
      pending_count: 0,
      win_rate_percent: 66.7,
    });

    const b = result.items.find((i) => i.identity_id === 'id-b');
    expect(b).toMatchObject({
      application_count: 2,
      won_count: 1,
      lost_count: 0,
      pending_count: 1,
      win_rate_percent: 100,
    });
  });
});
