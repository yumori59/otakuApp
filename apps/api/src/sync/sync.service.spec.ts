import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { IdentitiesService } from '../identities/identities.service';
import { PrismaService } from '../prisma/prisma.service';
import { SyncService } from './sync.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';

function makeDelegate(rows: unknown[] = []) {
  return {
    findMany: jest.fn().mockResolvedValue(rows),
    findUnique: jest.fn(),
    upsert: jest.fn().mockResolvedValue({}),
  };
}

type Delegates = {
  identity: ReturnType<typeof makeDelegate>;
  membership: ReturnType<typeof makeDelegate>;
  tour: ReturnType<typeof makeDelegate>;
  event: ReturnType<typeof makeDelegate>;
  application: ReturnType<typeof makeDelegate>;
  applicationCompanion: ReturnType<typeof makeDelegate>;
};

describe('SyncService', () => {
  // `tx` は $transaction コールバックへ渡される、実 DB のトランザクション接続を
  // 模した独立オブジェクト。`prisma`（トランザクション外の接続）とはデリゲートを
  // 共有しない — 実装が誤って `this.prisma.xxx` を使うとテストが検出できるように。
  let tx: Delegates;
  let prisma: Delegates & { $transaction: jest.Mock };
  let identities: { ensureWithinLimit: jest.Mock };
  let service: SyncService;

  beforeEach(() => {
    tx = {
      identity: makeDelegate(),
      membership: makeDelegate(),
      tour: makeDelegate(),
      event: makeDelegate(),
      application: makeDelegate(),
      applicationCompanion: makeDelegate(),
    };
    prisma = {
      identity: makeDelegate([
        {
          id: IDENTITY_ID,
          ownerId: USER_ID,
          displayName: '自分',
          relation: 'self',
          color: '#0017C1',
          joinedOn: null,
          note: null,
          historyVisible: true,
          sortOrder: 0,
          createdAt: new Date('2026-07-30T00:00:00.000Z'),
          updatedAt: new Date('2026-07-31T10:00:00.000Z'),
          deletedAt: null,
        },
      ]),
      membership: makeDelegate(),
      tour: makeDelegate(),
      event: makeDelegate(),
      application: makeDelegate(),
      applicationCompanion: makeDelegate(),
      $transaction: jest.fn(async (fn: (tx: unknown) => Promise<void>) =>
        fn(tx),
      ),
    };
    identities = { ensureWithinLimit: jest.fn().mockResolvedValue(undefined) };
    service = new SyncService(
      prisma as unknown as PrismaService,
      identities as unknown as IdentitiesService,
    );
  });

  it('pull — cursor 以降の changes と next_cursor を返す', async () => {
    const result = await service.pull(USER_ID, '2026-07-30T00:00:00.000Z', [
      'identities',
    ]);

    expect(result.changes.identities).toHaveLength(1);
    expect(result.changes.identities[0]).toMatchObject({
      id: IDENTITY_ID,
      display_name: '自分',
    });
    expect(result.next_cursor).toBe('2026-07-31T10:00:00.000Z');
    expect(result.has_more).toBe(false);
  });

  it('push — サーバーが新しければ SYNC_LWW_REJECT', async () => {
    tx.identity.findUnique.mockResolvedValue({
      ownerId: USER_ID,
      updatedAt: new Date('2026-07-31T12:00:00.000Z'),
    });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'identities',
          op: 'upsert',
          id: IDENTITY_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: { display_name: '更新' },
        },
      ],
    });

    expect(result.accepted).toEqual([]);
    expect(result.rejected[0]).toMatchObject({
      id: IDENTITY_ID,
      code: 'SYNC_LWW_REJECT',
    });
  });

  it('push — 他人の id は reject', async () => {
    tx.identity.findUnique.mockResolvedValue({
      ownerId: OTHER_USER,
      updatedAt: new Date('2026-07-01T00:00:00.000Z'),
    });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'identities',
          op: 'upsert',
          id: IDENTITY_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: { display_name: '更新' },
        },
      ],
    });

    expect(result.rejected[0].code).toBe('SYNC_APPLY_FAILED');
  });

  it('push — 新規 identity は ensureWithinLimit を呼ぶ', async () => {
    tx.identity.findUnique.mockResolvedValue(null);

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'identities',
          op: 'upsert',
          id: IDENTITY_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: {
            display_name: '新規',
            relation: 'other',
            color: '#0017C1',
            history_visible: true,
            sort_order: 0,
          },
        },
      ],
    });

    expect(identities.ensureWithinLimit).toHaveBeenCalledWith(
      USER_ID,
      IDENTITY_ID,
      tx,
    );
    expect(result.accepted).toContain(IDENTITY_ID);
  });

  it('push — PLAN_LIMIT_IDENTITY は rejected に載せる', async () => {
    tx.identity.findUnique.mockResolvedValue(null);
    identities.ensureWithinLimit.mockRejectedValue(
      new AppError(ErrorCode.PLAN_LIMIT_IDENTITY, 'limit reached'),
    );

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'identities',
          op: 'upsert',
          id: IDENTITY_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: { display_name: '新規' },
        },
      ],
    });

    expect(result.rejected[0].code).toBe(ErrorCode.PLAN_LIMIT_IDENTITY);
  });

  it('push — 非 AppError は内部詳細を返さない', async () => {
    tx.identity.findUnique.mockResolvedValue(null);
    identities.ensureWithinLimit.mockRejectedValue(
      new Error('prisma P2002 unique constraint exploded at line 42'),
    );

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'identities',
          op: 'upsert',
          id: IDENTITY_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: { display_name: '新規' },
        },
      ],
    });

    expect(result.rejected[0]).toEqual({
      id: IDENTITY_ID,
      code: 'SYNC_APPLY_FAILED',
      message: 'failed to apply mutation',
    });
  });

  const EVENT_ID = '018f3c2a-bbbb-7c90-9d2a-000000000002';
  const TOUR_ID = '018f3c2a-cccc-7c90-9d2a-000000000003';
  const APPLICATION_ID = '018f3c2a-dddd-7c90-9d2a-000000000004';
  const MEMBERSHIP_ID = '018f3c2a-9999-7c90-9d2a-000000000007';

  it('AC-1 push — applications: 他人所有の event_id は SYNC_APPLY_FAILED で reject する', async () => {
    tx.application.findUnique.mockResolvedValue(null);
    tx.event.findUnique.mockResolvedValue({ ownerId: OTHER_USER });
    tx.identity.findUnique.mockResolvedValue({ ownerId: USER_ID });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'applications',
          op: 'upsert',
          id: APPLICATION_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: {
            event_id: EVENT_ID,
            rep_identity_id: IDENTITY_ID,
            status: 'applied',
          },
        },
      ],
    });

    expect(result.accepted).toEqual([]);
    expect(result.rejected[0]).toMatchObject({
      id: APPLICATION_ID,
      code: 'SYNC_APPLY_FAILED',
    });
    expect(result.rejected[0].message).toMatch(/event/);
  });

  it('AC-2 push — memberships: 他人所有の identity_id は SYNC_APPLY_FAILED で reject する', async () => {
    tx.membership.findUnique.mockResolvedValue(null);
    tx.identity.findUnique.mockResolvedValue({ ownerId: OTHER_USER });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'memberships',
          op: 'upsert',
          id: '018f3c2a-eeee-7c90-9d2a-000000000005',
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: {
            identity_id: IDENTITY_ID,
            fan_club_name_raw: '不正参照',
          },
        },
      ],
    });

    expect(result.accepted).toEqual([]);
    expect(result.rejected[0]).toMatchObject({ code: 'SYNC_APPLY_FAILED' });
    expect(result.rejected[0].message).toMatch(/identity/);
  });

  it('AC-3 push — events: 他人所有の tour_id は SYNC_APPLY_FAILED で reject する', async () => {
    tx.event.findUnique.mockResolvedValue(null);
    tx.tour.findUnique.mockResolvedValue({ ownerId: OTHER_USER });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'events',
          op: 'upsert',
          id: EVENT_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: { tour_id: TOUR_ID, name: '不正参照公演' },
        },
      ],
    });

    expect(result.accepted).toEqual([]);
    expect(result.rejected[0]).toMatchObject({ code: 'SYNC_APPLY_FAILED' });
    expect(result.rejected[0].message).toMatch(/tour/);
  });

  it('AC-4 push — 同一バッチ内で先に作成した親 (tour) を参照する子 (event) は accepted される', async () => {
    // 実 DB のトランザクション内での挙動 (tour.upsert 後に同一 tx の
    // findUnique が新規行を見える) をモックで再現する。
    let tourCreated = false;
    tx.tour.upsert.mockImplementation(async () => {
      tourCreated = true;
      return {};
    });
    tx.tour.findUnique.mockImplementation(async () =>
      tourCreated ? { ownerId: USER_ID, updatedAt: new Date(0) } : null,
    );
    tx.event.findUnique.mockResolvedValue(null);

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'tours',
          op: 'upsert',
          id: TOUR_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: { name: '新規ツアー' },
        },
        {
          collection: 'events',
          op: 'upsert',
          id: EVENT_ID,
          updated_at: '2026-07-31T10:00:01.000Z',
          payload: { tour_id: TOUR_ID, name: '新規公演' },
        },
      ],
    });

    expect(tx.tour.upsert).toHaveBeenCalled();
    // 実装が tx ではなく this.prisma を使う改悪をすると、tx 側にしか
    // 設定していないこのテストの状態遷移モックが効かなくなり検出できる。
    expect(prisma.tour.findUnique).not.toHaveBeenCalled();
    expect(result.rejected).toEqual([]);
    expect(result.accepted).toEqual([TOUR_ID, EVENT_ID]);
  });

  it('AC-5 push — application_companions: identity_id が null なら accepted される', async () => {
    tx.applicationCompanion.findUnique.mockResolvedValue(null);
    tx.application.findUnique.mockResolvedValue({ ownerId: USER_ID });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'application_companions',
          op: 'upsert',
          id: '018f3c2a-ffff-7c90-9d2a-000000000006',
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: {
            application_id: APPLICATION_ID,
            identity_id: null,
            display_name: 'テキスト同行者',
          },
        },
      ],
    });

    expect(result.rejected).toEqual([]);
    expect(result.accepted).toEqual(['018f3c2a-ffff-7c90-9d2a-000000000006']);
  });

  it('AC-6 push — applications: 他人所有の rep_membership_id は SYNC_APPLY_FAILED で reject する', async () => {
    tx.application.findUnique.mockResolvedValue(null);
    tx.event.findUnique.mockResolvedValue({ ownerId: USER_ID });
    tx.identity.findUnique.mockResolvedValue({ ownerId: USER_ID });
    tx.membership.findUnique.mockResolvedValue({ ownerId: OTHER_USER });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'applications',
          op: 'upsert',
          id: APPLICATION_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: {
            event_id: EVENT_ID,
            rep_identity_id: IDENTITY_ID,
            rep_membership_id: MEMBERSHIP_ID,
            status: 'applied',
          },
        },
      ],
    });

    expect(result.accepted).toEqual([]);
    expect(result.rejected[0]).toMatchObject({
      id: APPLICATION_ID,
      code: 'SYNC_APPLY_FAILED',
    });
    expect(result.rejected[0].message).toMatch(/membership/);
  });

  it('AC-7 push — applications: rep_membership_id が null なら accepted される', async () => {
    tx.application.findUnique.mockResolvedValue(null);
    tx.event.findUnique.mockResolvedValue({ ownerId: USER_ID });
    tx.identity.findUnique.mockResolvedValue({ ownerId: USER_ID });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'applications',
          op: 'upsert',
          id: APPLICATION_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: {
            event_id: EVENT_ID,
            rep_identity_id: IDENTITY_ID,
            rep_membership_id: null,
            status: 'applied',
          },
        },
      ],
    });

    expect(tx.membership.findUnique).not.toHaveBeenCalled();
    expect(result.rejected).toEqual([]);
    expect(result.accepted).toEqual([APPLICATION_ID]);
  });
});
