import { PrismaService } from '../prisma/prisma.service';
import { HomeService } from './home.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const NOW = new Date('2026-07-31T12:00:00.000Z');

describe('HomeService', () => {
  let prisma: {
    identity: { count: jest.Mock };
    membership: { findMany: jest.Mock };
    application: { findMany: jest.Mock };
  };
  let service: HomeService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      identity: { count: jest.fn().mockResolvedValue(3) },
      membership: {
        findMany: jest.fn().mockResolvedValue([
          {
            id: '018f3c2a-bbbb-7c90-9d2a-000000000002',
            fanClubNameRaw: 'FC B',
            renewalOn: new Date('2026-08-10T00:00:00.000Z'),
            identity: {
              displayName: '妹',
              color: '#FF0000',
            },
          },
          {
            id: '018f3c2a-bbbb-7c90-9d2a-000000000001',
            fanClubNameRaw: 'STELLARIS OFFICIAL FAN CLUB',
            renewalOn: new Date('2026-09-15T00:00:00.000Z'),
            identity: {
              displayName: '自分',
              color: '#0017C1',
            },
          },
        ]),
      },
      application: {
        findMany: jest.fn().mockResolvedValue([
          {
            id: '018f3c2a-cccc-7c90-9d2a-000000000001',
            status: 'applied',
            resultOn: new Date('2026-07-20T00:00:00.000Z'),
            event: { name: '大阪公演 Day1' },
            repIdentity: { displayName: '自分' },
          },
        ]),
      },
    };
    service = new HomeService(prisma as unknown as PrismaService);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('identity_count / renewals_within_30_days / pending_results を集計する', async () => {
    const result = await service.getSummary(USER_ID);

    expect(result.identity_count).toBe(3);
    expect(result.renewals_within_30_days).toBe(1);
    expect(result.pending_results).toBe(1);
    expect(result.upcoming_renewals).toHaveLength(2);
    expect(result.upcoming_renewals[0]).toMatchObject({
      membership_id: '018f3c2a-bbbb-7c90-9d2a-000000000002',
      days_until: 10,
      urgency: 'warning',
    });
    expect(result.upcoming_renewals[1]).toMatchObject({
      days_until: 46,
      urgency: 'ok',
    });
    expect(result.pending_applications[0]).toEqual({
      application_id: '018f3c2a-cccc-7c90-9d2a-000000000001',
      event_name: '大阪公演 Day1',
      result_on: '2026-07-20',
      rep_name: '自分',
      status: 'applied',
    });
  });
});
