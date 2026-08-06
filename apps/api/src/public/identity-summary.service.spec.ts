import { IdentitiesService } from '../identities/identities.service';
import { PrismaService } from '../prisma/prisma.service';
import { IdentitySummaryService } from './identity-summary.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const IDENTITY_A = '018f3c2a-aaaa-7c90-9d2a-000000000001';
const IDENTITY_B = '018f3c2a-aaaa-7c90-9d2a-000000000002';
const NOW = new Date('2026-08-02T10:00:00.000Z');

function identityResponse(id: string, overrides: Record<string, unknown> = {}) {
  return {
    id,
    display_name: '自分',
    relation: 'self',
    color: '#0017C1',
    joined_on: null,
    note: null,
    history_visible: true,
    sort_order: 0,
    created_at: NOW.toISOString(),
    updated_at: NOW.toISOString(),
    deleted_at: null,
    ...overrides,
  };
}

describe('IdentitySummaryService', () => {
  let prisma: { application: { groupBy: jest.Mock } };
  let identities: { list: jest.Mock };
  let service: IdentitySummaryService;

  beforeEach(() => {
    prisma = { application: { groupBy: jest.fn().mockResolvedValue([]) } };
    identities = { list: jest.fn().mockResolvedValue([]) };
    service = new IdentitySummaryService(
      prisma as unknown as PrismaService,
      identities as unknown as IdentitiesService,
    );
  });

  it('未削除の名義だけを対象にし、集計も ownerId スコープ (BE-4)', async () => {
    identities.list.mockResolvedValue([
      identityResponse(IDENTITY_A),
      identityResponse(IDENTITY_B, {
        display_name: '友人A',
        history_visible: false,
      }),
    ]);

    await service.build(USER_ID);

    expect(identities.list).toHaveBeenCalledWith(USER_ID, false);
    expect(prisma.application.groupBy).toHaveBeenCalledWith({
      by: ['repIdentityId', 'status'],
      where: {
        ownerId: USER_ID,
        deletedAt: null,
        repIdentityId: { in: [IDENTITY_A, IDENTITY_B] },
      },
      _count: { _all: true },
    });
  });

  it('application_count は未削除の全ステータス、won_count は status=won のみ', async () => {
    identities.list.mockResolvedValue([
      identityResponse(IDENTITY_A),
      identityResponse(IDENTITY_B, {
        display_name: '友人A',
        history_visible: false,
      }),
    ]);
    prisma.application.groupBy.mockResolvedValue([
      { repIdentityId: IDENTITY_A, status: 'applied', _count: { _all: 7 } },
      { repIdentityId: IDENTITY_A, status: 'won', _count: { _all: 5 } },
      { repIdentityId: IDENTITY_B, status: 'lost', _count: { _all: 2 } },
    ]);

    const rows = await service.build(USER_ID);

    expect(rows).toEqual([
      {
        displayName: '自分',
        historyVisible: true,
        applicationCount: 12,
        wonCount: 5,
      },
      {
        displayName: '友人A',
        historyVisible: false,
        applicationCount: 2,
        wonCount: 0,
      },
    ]);
  });

  it('申込 0 件の名義は 0 件で返す（行を落とさない）', async () => {
    identities.list.mockResolvedValue([identityResponse(IDENTITY_A)]);

    const rows = await service.build(USER_ID);

    expect(rows).toEqual([
      {
        displayName: '自分',
        historyVisible: true,
        applicationCount: 0,
        wonCount: 0,
      },
    ]);
  });

  it('名義が 0 件なら集計クエリを投げない', async () => {
    const rows = await service.build(USER_ID);

    expect(rows).toEqual([]);
    expect(prisma.application.groupBy).not.toHaveBeenCalled();
  });

  it('内部 UUID を返り値に含めない（公開ペイロードへの漏洩経路を作らない）', async () => {
    identities.list.mockResolvedValue([identityResponse(IDENTITY_A)]);

    const rows = await service.build(USER_ID);

    expect(JSON.stringify(rows)).not.toContain(IDENTITY_A);
    expect(JSON.stringify(rows)).not.toContain(USER_ID);
  });
});
