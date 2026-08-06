import { ErrorCode } from '../common/errors/error-codes';
import { TourMatrixInternalRow } from '../tours/tour-matrix.service';
import { shareItemKey, shareItemRev } from './share-item-key';
import {
  ShareWriteContext,
  createShareItemAnnotator,
  resolveEditableEventIds,
} from './share-write';

const TOKEN_HASH = 'a'.repeat(64);
const UPDATED_AT = new Date('2026-08-02T10:00:00.000Z');

function eventId(n: number): string {
  return `018f3c2a-eeee-7c90-9d2a-00000000000${n}`;
}

function applicationId(n: number): string {
  return `018f3c2a-cccc-7c90-9d2a-00000000000${n}`;
}

function row(
  overrides: Partial<TourMatrixInternalRow> = {},
): TourMatrixInternalRow {
  return {
    event_id: eventId(1),
    event_name: '大阪公演 Day1',
    venue_name: '大阪城ホール',
    event_date: '2026-08-20',
    application_id: applicationId(1),
    round_name: 'FC1次',
    status: 'applied',
    seat_raw: null,
    result_on: null,
    rep_identity_id: '018f3c2a-aaaa-7c90-9d2a-000000000001',
    rep_name: '自分',
    rep_color: '#0017C1',
    companion_names: [],
    rep_history_visible: true,
    ...overrides,
  };
}

/** 公演 n 件（1 公演 1 申込）の matrix 行。 */
function rowsForEvents(count: number): TourMatrixInternalRow[] {
  return Array.from({ length: count }, (_unused, index) =>
    row({
      event_id: eventId(index + 1),
      application_id: applicationId(index + 1),
      event_name: `公演 ${index + 1}`,
    }),
  );
}

function context(
  rows: TourMatrixInternalRow[],
  eventLimit: number | null,
): ShareWriteContext {
  return {
    tokenHash: TOKEN_HASH,
    eventLimit,
    updatedAtByApplicationId: new Map(
      rows.map((current) => [current.application_id, UPDATED_AT]),
    ),
  };
}

describe('share-write', () => {
  describe('resolveEditableEventIds', () => {
    it('AC-SW-10 limit=3 なら行順の先頭 3 公演だけを返す', () => {
      const rows = rowsForEvents(5);

      const ids = resolveEditableEventIds(rows, 3);

      expect([...ids]).toEqual([eventId(1), eventId(2), eventId(3)]);
    });

    it('AC-SW-10b limit=null（plus）は全公演', () => {
      const rows = rowsForEvents(5);

      expect(resolveEditableEventIds(rows, null).size).toBe(5);
    });

    it('同一公演の複数申込は 1 公演として数える', () => {
      const rows = [
        row({ event_id: eventId(1), application_id: applicationId(1) }),
        row({ event_id: eventId(1), application_id: applicationId(2) }),
        row({ event_id: eventId(2), application_id: applicationId(3) }),
        row({ event_id: eventId(3), application_id: applicationId(4) }),
        row({ event_id: eventId(4), application_id: applicationId(5) }),
      ];

      const ids = resolveEditableEventIds(rows, 3);

      expect([...ids]).toEqual([eventId(1), eventId(2), eventId(3)]);
    });

    it('limit=0 なら 1 件も編集できない', () => {
      expect(resolveEditableEventIds(rowsForEvents(3), 0).size).toBe(0);
    });
  });

  describe('createShareItemAnnotator', () => {
    it('AC-SW-07 item_key / rev / editable を返す', () => {
      const rows = rowsForEvents(1);
      const annotate = createShareItemAnnotator(rows, context(rows, 3));

      expect(annotate(rows[0])).toEqual({
        item_key: shareItemKey(TOKEN_HASH, applicationId(1)),
        rev: shareItemRev(TOKEN_HASH, applicationId(1), UPDATED_AT),
        editable: true,
      });
    });

    it('AC-SW-16 history_visible=false なら editable:false', () => {
      const rows = [row({ rep_history_visible: false })];
      const annotate = createShareItemAnnotator(rows, context(rows, 3));

      expect(annotate(rows[0]).editable).toBe(false);
    });

    it('AC-SW-10 上限を超えた公演の行は editable:false（行自体は残る）', () => {
      const rows = rowsForEvents(5);
      const annotate = createShareItemAnnotator(rows, context(rows, 3));

      expect(rows.map((current) => annotate(current).editable)).toEqual([
        true,
        true,
        true,
        false,
        false,
      ]);
    });

    it('AC-SW-17 プラン超過と非公開名義で editable の値が区別できない', () => {
      const rows = [
        row({ event_id: eventId(1), application_id: applicationId(1) }),
        row({
          event_id: eventId(2),
          application_id: applicationId(2),
          rep_history_visible: false,
        }),
      ];
      const annotate = createShareItemAnnotator(rows, context(rows, 1));

      const overLimit = annotate(rows[1]);
      const hidden = annotate(rows[1]);
      expect(overLimit.editable).toBe(false);
      expect(hidden.editable).toBe(false);
      // 理由を示すキーが増えていない
      expect(Object.keys(overLimit).sort()).toEqual(
        ['editable', 'item_key', 'rev'].sort(),
      );
    });

    it('updated_at が取れない行は黙って落とさず INTERNAL（BE-2）', () => {
      const rows = rowsForEvents(1);
      const ctx: ShareWriteContext = {
        tokenHash: TOKEN_HASH,
        eventLimit: null,
        updatedAtByApplicationId: new Map(),
      };
      const annotate = createShareItemAnnotator(rows, ctx);

      expect(() => annotate(rows[0])).toThrow(
        expect.objectContaining({ code: ErrorCode.INTERNAL }) as Error,
      );
      // 内部 UUID を message に出さない
      const error = (() => {
        try {
          annotate(rows[0]);
          return null;
        } catch (thrown) {
          return thrown as Error;
        }
      })();
      expect(error?.message).not.toContain(applicationId(1));
    });
  });
});
