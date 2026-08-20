import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { EntitlementsService } from '../entitlements/entitlements.service';
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
    findFirst: jest.fn().mockResolvedValue(null),
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

  it(
    'push — 非 AppError (DB由来の想定外エラー) は rejected に積まず rethrow する ' +
      '(2026-08-18: 握り潰すと同一トランザクション内の他の accepted が実は未コミットのまま' +
      '「成功」と返ってしまう。outbox は何もmarkSyncedされないので安全に再送できる)',
    async () => {
      tx.identity.findUnique.mockResolvedValue(null);
      identities.ensureWithinLimit.mockRejectedValue(
        new Error('prisma P2002 unique constraint exploded at line 42'),
      );

      await expect(
        service.push(USER_ID, {
          mutations: [
            {
              collection: 'identities',
              op: 'upsert',
              id: IDENTITY_ID,
              updated_at: '2026-07-31T10:00:00.000Z',
              payload: { display_name: '新規' },
            },
          ],
        }),
      ).rejects.toThrow('prisma P2002 unique constraint exploded at line 42');
    },
  );

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

  it(
    'AC-8 push — tours: 事前の名前重複チェックにより Postgres の unique 制約違反' +
      '(P2002) を起こさせず、同一バッチ内の後続の正常な mutation も transaction' +
      ' abort に巻き込まれない (旧: 巻き添えを実測していたテストを、今回の修正で' +
      '巻き添えが起きなくなることの回帰ガードへ更新)',
    async () => {
      const FAILING_TOUR_ID = TOUR_ID;
      const OK_TOUR_ID = '018f3c2a-cccc-7c90-9d2a-000000000098';

      tx.tour.findUnique.mockResolvedValue(null); // どちらも新規 tour 扱い
      // 事前チェック (findFirst): FAILING_TOUR_ID と同じ名前を持つ別 id の
      // ツアーが既に存在する。OK_TOUR_ID は重複なし。
      tx.tour.findFirst.mockImplementation(
        async (args: { where: { name: string } }) => {
          if (args.where.name === '既存ツアーと同名 (unique 違反)') {
            return { id: 'other-existing-tour-id' };
          }
          return null;
        },
      );

      const result = await service.push(USER_ID, {
        mutations: [
          {
            collection: 'tours',
            op: 'upsert',
            id: FAILING_TOUR_ID,
            updated_at: '2026-07-31T10:00:00.000Z',
            payload: { name: '既存ツアーと同名 (unique 違反)' },
          },
          {
            collection: 'tours',
            op: 'upsert',
            id: OK_TOUR_ID,
            updated_at: '2026-07-31T10:00:01.000Z',
            payload: { name: '本来は正常に作成できるはずのツアー' },
          },
        ],
      });

      // 事前チェックで検出されるため upsert 自体が呼ばれず、Postgres エラーも
      // transaction abort も発生しない。OK_TOUR_ID は正常に accepted される。
      expect(result.accepted).toEqual([OK_TOUR_ID]);
      expect(result.rejected).toEqual([
        {
          id: FAILING_TOUR_ID,
          code: 'SYNC_APPLY_FAILED',
          message: 'tour name already exists',
        },
      ]);
      expect(tx.tour.upsert).toHaveBeenCalledTimes(1);
      expect(tx.tour.upsert).toHaveBeenCalledWith(
        expect.objectContaining({ where: { id: OK_TOUR_ID } }),
      );
    },
  );

  it('AC-9 push — tours: 同一バッチで同名・別 id のツアー作成が reject されても、' +
    '無関係な名義の新規作成は accepted される (巻き添え防止の回帰ガード)', async () => {
    tx.tour.findUnique.mockResolvedValue(null);
    tx.tour.findFirst.mockResolvedValue({ id: 'existing-tour-id' }); // 常に重複あり
    tx.identity.findUnique.mockResolvedValue(null);

    const DUP_TOUR_ID = '018f3c2a-cccc-7c90-9d2a-000000000097';
    const NEW_IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000099';

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'identities',
          op: 'upsert',
          id: NEW_IDENTITY_ID,
          updated_at: '2026-07-31T10:00:00.000Z',
          payload: {
            display_name: '無関係な名義',
            relation: 'other',
            color: '#0017C1',
            history_visible: true,
            sort_order: 0,
          },
        },
        {
          collection: 'tours',
          op: 'upsert',
          id: DUP_TOUR_ID,
          updated_at: '2026-07-31T10:00:01.000Z',
          payload: { name: '重複ツアー' },
        },
      ],
    });

    expect(result.accepted).toEqual([NEW_IDENTITY_ID]);
    expect(result.rejected).toEqual([
      {
        id: DUP_TOUR_ID,
        code: 'SYNC_APPLY_FAILED',
        message: 'tour name already exists',
      },
    ]);
    expect(tx.tour.upsert).not.toHaveBeenCalled();
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

  it('AC-10 push — identities: tombstone (deleted_at 付き) upsert は ensureWithinLimit を呼ばずに accepted される', async () => {
    tx.identity.findUnique.mockResolvedValue({
      ownerId: USER_ID,
      updatedAt: new Date('2026-07-31T09:00:00.000Z'),
    });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'identities',
          op: 'upsert',
          id: IDENTITY_ID,
          updated_at: '2026-08-01T00:00:00.000Z',
          payload: {
            display_name: '自分',
            deleted_at: '2026-08-01T00:00:00.000Z',
          },
        },
      ],
    });

    expect(identities.ensureWithinLimit).not.toHaveBeenCalled();
    expect(result.rejected).toEqual([]);
    expect(result.accepted).toEqual([IDENTITY_ID]);
  });

  it(
    'AC-11 push — applications: 削除済み (tombstone) の identity を参照する ' +
      'applications の tombstone push も accepted される (削除済み親を参照する子の tombstone を弾かない)',
    async () => {
      tx.application.findUnique.mockResolvedValue({
        ownerId: USER_ID,
        updatedAt: new Date('2026-07-31T09:00:00.000Z'),
      });
      tx.event.findUnique.mockResolvedValue({ ownerId: USER_ID });
      // 参照先 identity は既に tombstone 済み（deletedAt が立っている）が、
      // validateForeignKeys は deletedAt を条件に含めないため ownerId 一致のみで通る。
      tx.identity.findUnique.mockResolvedValue({
        ownerId: USER_ID,
        deletedAt: new Date('2026-08-01T00:00:00.000Z'),
      });

      const result = await service.push(USER_ID, {
        mutations: [
          {
            collection: 'applications',
            op: 'upsert',
            id: APPLICATION_ID,
            updated_at: '2026-08-01T00:00:00.000Z',
            payload: {
              event_id: EVENT_ID,
              rep_identity_id: IDENTITY_ID,
              status: 'applied',
              deleted_at: '2026-08-01T00:00:00.000Z',
            },
          },
        ],
      });

      expect(result.rejected).toEqual([]);
      expect(result.accepted).toEqual([APPLICATION_ID]);
    },
  );

  it('AC-12 push — memberships: tombstone (deleted_at 付き) upsert は accepted される', async () => {
    tx.membership.findUnique.mockResolvedValue({
      ownerId: USER_ID,
      updatedAt: new Date('2026-07-31T09:00:00.000Z'),
    });
    tx.identity.findUnique.mockResolvedValue({ ownerId: USER_ID });

    const result = await service.push(USER_ID, {
      mutations: [
        {
          collection: 'memberships',
          op: 'upsert',
          id: MEMBERSHIP_ID,
          updated_at: '2026-08-01T00:00:00.000Z',
          payload: {
            identity_id: IDENTITY_ID,
            fan_club_name_raw: '削除対象FC',
            deleted_at: '2026-08-01T00:00:00.000Z',
          },
        },
      ],
    });

    expect(result.rejected).toEqual([]);
    expect(result.accepted).toEqual([MEMBERSHIP_ID]);
  });

  it(
    'AC-13 push — identities: 名義上限に達したユーザーが既存 (新規ではない) identity を ' +
      '編集 upsert しても PLAN_LIMIT_IDENTITY にならず accepted される ' +
      '(IdentitiesService.ensureWithinLimit を SyncService 経由の統合で回帰確認する)',
    async () => {
      const entitlementsStub = { identityLimit: jest.fn().mockResolvedValue(1) };
      const realIdentities = new IdentitiesService(
        prisma as unknown as PrismaService,
        entitlementsStub as unknown as EntitlementsService,
      );
      const localService = new SyncService(
        prisma as unknown as PrismaService,
        realIdentities,
      );

      // SyncService 自身の既存/LWW チェック用
      tx.identity.findUnique.mockResolvedValue({
        ownerId: USER_ID,
        updatedAt: new Date('2026-07-31T09:00:00.000Z'),
      });
      // IdentitiesService.ensureWithinLimit の既存判定用 (deletedAt:null で既存行が見つかる → 上限チェックをスキップ)
      tx.identity.findFirst.mockResolvedValue({
        id: IDENTITY_ID,
        ownerId: USER_ID,
        deletedAt: null,
      });

      const result = await localService.push(USER_ID, {
        mutations: [
          {
            collection: 'identities',
            op: 'upsert',
            id: IDENTITY_ID,
            updated_at: '2026-08-01T00:00:00.000Z',
            payload: {
              display_name: '編集後の表示名',
              relation: 'other',
              color: '#0017C1',
              history_visible: true,
              sort_order: 0,
            },
          },
        ],
      });

      expect(entitlementsStub.identityLimit).not.toHaveBeenCalled();
      expect(result.rejected).toEqual([]);
      expect(result.accepted).toEqual([IDENTITY_ID]);
    },
  );
});
