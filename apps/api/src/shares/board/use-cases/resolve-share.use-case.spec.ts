import { ShareLink, Tour } from '@prisma/client';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { EntitlementsService } from '../../../entitlements/entitlements.service';
import { SharesService } from '../../shares.service';
import {
  TourMatrixInternalRow,
  TourMatrixService,
} from '../../../tours/tour-matrix.service';
import { IdentitySummaryService } from '../identity-summary.service';
import { MASKED_IDENTITY_NAME } from '../public-share.presenter';
import { shareItemKey, shareItemRev } from '../share-item-key';
import { SharedApplicationsService } from '../shared-applications.service';
import { ResolveShareUseCase } from './resolve-share.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const EVENT_ID = '018f3c2a-eeee-7c90-9d2a-000000000001';
const APPLICATION_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-02T10:00:00.000Z');
const TOKEN_HASH = 'a'.repeat(64);
const UPDATED_AT = new Date('2026-08-01T09:00:00.000Z');

function eventId(n: number): string {
  return `018f3c2a-eeee-7c90-9d2a-00000000000${n}`;
}

function applicationIdOf(n: number): string {
  return `018f3c2a-cccc-7c90-9d2a-00000000000${n}`;
}

function shareRow(overrides: Partial<ShareLink> = {}): ShareLink {
  return {
    id: SHARE_ID,
    ownerId: USER_ID,
    scopeType: 'tour',
    scopeId: TOUR_ID,
    tokenHash: TOKEN_HASH,
    permission: 'read',
    maskMemberNo: true,
    expiresAt: new Date('2026-08-31T00:00:00.000Z'),
    revokedAt: null,
    viewCount: 3,
    lastViewedAt: null,
    editCount: 0,
    lastEditedAt: null,
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
    ...overrides,
  } as ShareLink;
}

function tourRow(): Tour {
  return {
    id: TOUR_ID,
    ownerId: USER_ID,
    name: 'STELLARIS LIVE TOUR 2026',
    artistNameRaw: 'STELLARIS',
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
  } as Tour;
}

function matrixRow(
  overrides: Partial<TourMatrixInternalRow> = {},
): TourMatrixInternalRow {
  return {
    event_id: EVENT_ID,
    event_name: '大阪公演 Day1',
    venue_name: '大阪城ホール',
    event_date: '2026-08-20',
    application_id: APPLICATION_ID,
    round_name: 'FC1次',
    status: 'applied',
    seat_raw: 'アリーナ A-12',
    result_on: '2026-07-20',
    rep_identity_id: IDENTITY_ID,
    rep_name: '自分',
    rep_color: '#0017C1',
    companion_names: ['妹'],
    rep_history_visible: true,
    ...overrides,
  };
}

/** ネストしたオブジェクト・配列を再帰的に走査してキー名を全部集める。 */
function collectKeys(value: unknown, acc: string[] = []): string[] {
  if (Array.isArray(value)) {
    value.forEach((v) => collectKeys(v, acc));
    return acc;
  }
  if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      acc.push(key);
      collectKeys(child, acc);
    }
  }
  return acc;
}

describe('ResolveShareUseCase', () => {
  let shares: { recordView: jest.Mock };
  let tourMatrix: { build: jest.Mock };
  let summary: { build: jest.Mock };
  let sharedApplications: { findUpdatedAtByTour: jest.Mock };
  let entitlements: { shareWriteEventLimit: jest.Mock };
  let useCase: ResolveShareUseCase;

  /** matrix 行と updated_at マップを同時に差し替える。 */
  function setRows(rows: TourMatrixInternalRow[]): void {
    tourMatrix.build.mockResolvedValue({ tour: tourRow(), rows });
    sharedApplications.findUpdatedAtByTour.mockResolvedValue(
      new Map(rows.map((row) => [row.application_id, UPDATED_AT])),
    );
  }

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    shares = {
      recordView: jest.fn().mockResolvedValue(undefined),
    };
    tourMatrix = {
      build: jest.fn().mockResolvedValue({ tour: tourRow(), rows: [matrixRow()] }),
    };
    summary = { build: jest.fn().mockResolvedValue([]) };
    sharedApplications = {
      findUpdatedAtByTour: jest
        .fn()
        .mockResolvedValue(new Map([[APPLICATION_ID, UPDATED_AT]])),
    };
    entitlements = { shareWriteEventLimit: jest.fn().mockResolvedValue(3) };

    useCase = new ResolveShareUseCase(
      shares as unknown as SharesService,
      tourMatrix as unknown as TourMatrixService,
      summary as unknown as IdentitySummaryService,
      sharedApplications as unknown as SharedApplicationsService,
      entitlements as unknown as EntitlementsService,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('scope_type = tour', () => {
    it('AC-SH-13 有効な閲覧で view_count が +1 され last_viewed_at が更新される', async () => {
      const payload = await useCase.execute(shareRow());

      expect(shares.recordView).toHaveBeenCalledWith(SHARE_ID, NOW);
      expect(payload.generated_at).toBe(NOW.toISOString());
    });

    it('共有元オーナーの ownerId で matrix を組み立てる (BE-4)', async () => {
      await useCase.execute(shareRow());
      expect(tourMatrix.build).toHaveBeenCalledWith(USER_ID, TOUR_ID);
    });

    it('契約どおりの tour ペイロードを返す', async () => {
      const payload = await useCase.execute(shareRow());

      expect(payload).toEqual({
        scope_type: 'tour',
        permission: 'read',
        tour: { name: 'STELLARIS LIVE TOUR 2026', artist_name: 'STELLARIS' },
        generated_at: NOW.toISOString(),
        items: [
          {
            event_name: '大阪公演 Day1',
            venue: '大阪城ホール',
            event_date: '2026-08-20',
            round_name: 'FC1次',
            rep_name: '自分',
            rep_color: '#0017C1',
            companions: ['妹'],
            status: 'applied',
            seat: 'アリーナ A-12',
          },
        ],
      });
    });

    it('AC-SH-15 history_visible=false の行は rep_name / rep_color / seat をマスクする (E-11)', async () => {
      tourMatrix.build.mockResolvedValue({
        tour: tourRow(),
        rows: [
          matrixRow({
            rep_history_visible: false,
            rep_name: '友人A',
            rep_color: '#FF0000',
            seat_raw: 'アリーナ A-12',
          }),
        ],
      });

      const payload = await useCase.execute(shareRow());
      const item = (payload as unknown as { items: Record<string, unknown>[] }).items[0];

      expect(item.rep_name).toBe(MASKED_IDENTITY_NAME);
      expect(item.rep_color).toBeNull();
      expect(item.seat).toBeNull();
      expect(JSON.stringify(payload)).not.toContain('友人A');
      expect(JSON.stringify(payload)).not.toContain('アリーナ A-12');
    });

    it('AC-SH-16 会員番号 / owner_id / account_id / shared_with / 内部 UUID を含まない (FR-SH-10)', async () => {
      tourMatrix.build.mockResolvedValue({
        tour: tourRow(),
        rows: [matrixRow(), matrixRow({ rep_history_visible: false })],
      });

      const payload = await useCase.execute(shareRow());
      const keys = collectKeys(payload);
      const json = JSON.stringify(payload);

      for (const forbidden of [
        'member_no',
        'member_no_last4',
        'owner_id',
        'ownerId',
        'account_id',
        'shared_with_account_ids',
        'shared_with',
        'identity_id',
        'rep_identity_id',
        'application_id',
        'event_id',
        'tour_id',
        'id',
        'token',
        'token_hash',
      ]) {
        expect(keys).not.toContain(forbidden);
      }
      for (const forbidden of [
        USER_ID,
        SHARE_ID,
        TOUR_ID,
        EVENT_ID,
        APPLICATION_ID,
        IDENTITY_ID,
        'ACC-3F9A21',
      ]) {
        expect(json).not.toContain(forbidden);
      }
    });

    it('AC-SH-17 application 0 件でも 200 + items: []（404 にしない — E-10）', async () => {
      tourMatrix.build.mockResolvedValue({ tour: tourRow(), rows: [] });

      const payload = await useCase.execute(shareRow());

      expect(payload).toMatchObject({ scope_type: 'tour', items: [] });
      expect(shares.recordView).toHaveBeenCalledTimes(1);
    });

    it('共有元 tour が削除済み (NOT_FOUND) なら SHARE_INVALID 404 にすり替え、内部 id を漏らさない', async () => {
      tourMatrix.build.mockRejectedValue(
        AppError.notFound(`tour not found: ${TOUR_ID}`),
      );

      const error = (await useCase
        .execute(shareRow())
        .catch((e: unknown) => e)) as AppError;

      expect(error.code).toBe(ErrorCode.SHARE_INVALID);
      expect(JSON.stringify(error.getResponse())).not.toContain(TOUR_ID);
      expect(shares.recordView).not.toHaveBeenCalled();
    });

    it('AC-SW-06 read リンクの item に item_key / rev / editable が現れない', async () => {
      const payload = await useCase.execute(shareRow());
      const keys = collectKeys(payload);

      expect(payload).toMatchObject({ permission: 'read' });
      for (const forbidden of ['item_key', 'rev', 'editable']) {
        expect(keys).not.toContain(forbidden);
      }
      // read リンクでは rev の材料すら引かない
      expect(sharedApplications.findUpdatedAtByTour).not.toHaveBeenCalled();
      expect(entitlements.shareWriteEventLimit).not.toHaveBeenCalled();
    });

    it('scope_id が欠けた tour 共有は SHARE_INVALID 404', async () => {
      await expect(
        useCase.execute(shareRow({ scopeId: null })),
      ).rejects.toMatchObject({
        code: ErrorCode.SHARE_INVALID,
      });
      expect(tourMatrix.build).not.toHaveBeenCalled();
    });
  });

  describe('permission = write (api-contract-delta.md §4)', () => {
    it('AC-SW-07 item に item_key / rev / editable が付く', async () => {
      const payload = await useCase.execute(shareRow({ permission: 'write' }));
      const item = (payload as unknown as { items: Record<string, unknown>[] })
        .items[0];

      expect(payload).toMatchObject({ permission: 'write' });
      expect(item.item_key).toBe(shareItemKey(TOKEN_HASH, APPLICATION_ID));
      expect(item.rev).toBe(
        shareItemRev(TOKEN_HASH, APPLICATION_ID, UPDATED_AT),
      );
      expect(item.editable).toBe(true);
    });

    it('AC-SW-08 同じ application でもリンク（token_hash）が違えば item_key が違う', async () => {
      const first = await useCase.execute(shareRow({ permission: 'write' }));
      const second = await useCase.execute(
        shareRow({ permission: 'write', tokenHash: 'c'.repeat(64) }),
      );

      const keyOf = (payload: unknown) =>
        (payload as { items: { item_key: string }[] }).items[0].item_key;
      expect(keyOf(first)).not.toBe(keyOf(second));
    });

    it('AC-SW-10 free (limit=3) は先頭 3 公演だけ editable:true・全行返る', async () => {
      setRows(
        Array.from({ length: 5 }, (_unused, index) =>
          matrixRow({
            event_id: eventId(index + 1),
            application_id: applicationIdOf(index + 1),
            event_name: `公演 ${index + 1}`,
          }),
        ),
      );

      const payload = await useCase.execute(shareRow({ permission: 'write' }));
      const items = (payload as unknown as { items: { editable: boolean }[] })
        .items;

      expect(items).toHaveLength(5);
      expect(items.map((item) => item.editable)).toEqual([
        true,
        true,
        true,
        false,
        false,
      ]);
    });

    it('AC-SW-10b オーナーが plus なら同じリンクでも全行 editable:true（閲覧時に判定）', async () => {
      entitlements.shareWriteEventLimit.mockResolvedValue(null);
      setRows(
        Array.from({ length: 5 }, (_unused, index) =>
          matrixRow({
            event_id: eventId(index + 1),
            application_id: applicationIdOf(index + 1),
          }),
        ),
      );

      const payload = await useCase.execute(shareRow({ permission: 'write' }));
      const items = (payload as unknown as { items: { editable: boolean }[] })
        .items;

      expect(items.every((item) => item.editable)).toBe(true);
      expect(entitlements.shareWriteEventLimit).toHaveBeenCalledWith(USER_ID);
    });

    it('AC-SW-16 history_visible=false の行は editable:false かつマスク済み', async () => {
      setRows([
        matrixRow({
          rep_history_visible: false,
          rep_name: '友人A',
          seat_raw: 'アリーナ A-12',
        }),
      ]);

      const payload = await useCase.execute(shareRow({ permission: 'write' }));
      const item = (payload as unknown as { items: Record<string, unknown>[] })
        .items[0];

      expect(item.editable).toBe(false);
      expect(item.rep_name).toBe(MASKED_IDENTITY_NAME);
      expect(item.seat).toBeNull();
      expect(JSON.stringify(payload)).not.toContain('アリーナ A-12');
    });

    it('AC-SW-22 write でも内部 UUID / owner_id / account_id / token_hash を含まない', async () => {
      setRows([matrixRow(), matrixRow({ rep_history_visible: false })]);

      const payload = await useCase.execute(shareRow({ permission: 'write' }));
      const keys = collectKeys(payload);
      const json = JSON.stringify(payload);

      for (const forbidden of [
        'application_id',
        'event_id',
        'tour_id',
        'identity_id',
        'rep_identity_id',
        'owner_id',
        'account_id',
        'member_no',
        'token',
        'token_hash',
      ]) {
        expect(keys).not.toContain(forbidden);
      }
      for (const forbidden of [
        USER_ID,
        SHARE_ID,
        TOUR_ID,
        EVENT_ID,
        APPLICATION_ID,
        IDENTITY_ID,
        TOKEN_HASH,
        'ACC-3F9A21',
      ]) {
        expect(json).not.toContain(forbidden);
      }
    });

    it('AC-SH-13 write リンクの閲覧でも view_count を +1 する', async () => {
      await useCase.execute(shareRow({ permission: 'write' }));
      expect(shares.recordView).toHaveBeenCalledWith(SHARE_ID, NOW);
    });

    it('items が 0 件なら updated_at を引かずに 200 + items: []', async () => {
      setRows([]);

      const payload = await useCase.execute(shareRow({ permission: 'write' }));

      expect(payload).toMatchObject({ permission: 'write', items: [] });
      expect(sharedApplications.findUpdatedAtByTour).not.toHaveBeenCalled();
    });

    it('未知の permission は黙って read に落とさず INTERNAL 500（BE-2）', async () => {
      await expect(
        useCase.execute(shareRow({ permission: 'admin' })),
      ).rejects.toMatchObject({
        code: ErrorCode.INTERNAL,
      });
      expect(shares.recordView).not.toHaveBeenCalled();
    });
  });

  describe('scope_type = identity_summary', () => {
    beforeEach(() => {
      summary.build.mockResolvedValue([
        {
          displayName: '自分',
          historyVisible: true,
          applicationCount: 12,
          wonCount: 5,
        },
        {
          displayName: '友人A',
          historyVisible: false,
          applicationCount: 7,
          wonCount: 2,
        },
      ]);
    });

    function identitySummaryRow(): ShareLink {
      return shareRow({ scopeType: 'identity_summary', scopeId: null });
    }

    it('AC-SH-18 visible:false の名義は件数キー自体を含めない (D10)', async () => {
      const payload = await useCase.execute(identitySummaryRow());

      expect(payload).toEqual({
        scope_type: 'identity_summary',
        permission: 'read',
        generated_at: NOW.toISOString(),
        items: [
          { name: '自分', visible: true, application_count: 12, won_count: 5 },
          { name: '友人A', visible: false },
        ],
      });
      const hidden = (payload as unknown as { items: Record<string, unknown>[] }).items[1];
      expect(Object.keys(hidden)).toEqual(['name', 'visible']);
      expect('application_count' in hidden).toBe(false);
      expect('won_count' in hidden).toBe(false);
      expect(JSON.stringify(payload)).not.toContain('7');
    });

    it('AC-SH-16 identity_summary も内部 UUID / account_id を含まない', async () => {
      const payload = await useCase.execute(identitySummaryRow());
      const keys = collectKeys(payload);
      const json = JSON.stringify(payload);

      for (const forbidden of ['id', 'identity_id', 'owner_id', 'account_id']) {
        expect(keys).not.toContain(forbidden);
      }
      expect(json).not.toContain(USER_ID);
      expect(json).not.toContain(IDENTITY_ID);
      expect(json).not.toContain('ACC-3F9A21');
    });

    it('共有元オーナーの ownerId で集計する (BE-4)', async () => {
      await useCase.execute(identitySummaryRow());
      expect(summary.build).toHaveBeenCalledWith(USER_ID);
      expect(tourMatrix.build).not.toHaveBeenCalled();
    });
  });

  it('未知の scope_type は黙って落とさず INTERNAL 500（BE-2）', async () => {
    await expect(
      useCase.execute(shareRow({ scopeType: 'calendar' })),
    ).rejects.toMatchObject({
      code: ErrorCode.INTERNAL,
    });
    expect(shares.recordView).not.toHaveBeenCalled();
  });
});
