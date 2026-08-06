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

describe('SyncService', () => {
  let identityDelegate: ReturnType<typeof makeDelegate>;
  let prisma: {
    identity: ReturnType<typeof makeDelegate>;
    membership: ReturnType<typeof makeDelegate>;
    tour: ReturnType<typeof makeDelegate>;
    event: ReturnType<typeof makeDelegate>;
    application: ReturnType<typeof makeDelegate>;
    applicationCompanion: ReturnType<typeof makeDelegate>;
    $transaction: jest.Mock;
  };
  let identities: { ensureWithinLimit: jest.Mock };
  let service: SyncService;

  beforeEach(() => {
    identityDelegate = makeDelegate([
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
    ]);
    prisma = {
      identity: identityDelegate,
      membership: makeDelegate(),
      tour: makeDelegate(),
      event: makeDelegate(),
      application: makeDelegate(),
      applicationCompanion: makeDelegate(),
      $transaction: jest.fn(async (fn: (tx: unknown) => Promise<void>) =>
        fn(prisma),
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
    identityDelegate.findUnique.mockResolvedValue({
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
    identityDelegate.findUnique.mockResolvedValue({
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
    identityDelegate.findUnique.mockResolvedValue(null);

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
      prisma,
    );
    expect(result.accepted).toContain(IDENTITY_ID);
  });

  it('push — PLAN_LIMIT_IDENTITY は rejected に載せる', async () => {
    identityDelegate.findUnique.mockResolvedValue(null);
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
    identityDelegate.findUnique.mockResolvedValue(null);
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
});
