import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { TourMatrixInternalRow } from '../../tours/tour-matrix.service';
import { shareItemKey, shareItemRev } from './share-item-key';

/**
 * `permission:"write"` の共有リンクで item に足す 3 キー
 * (`item_key` / `rev` / `editable`) の**計算だけ**を担うモジュール
 * （api-contract-delta.md §4）。マスキングと同じく単一責務にする。
 *
 * 判定は発行時ではなく**閲覧・更新のたび**に評価する。したがって
 * 公演の追加やプランのダウングレードに自動追従する。
 */

export interface ShareWriteContext {
  /** HMAC の鍵。`share_links.token_hash`（クライアントには出さない）。 */
  tokenHash: string;
  /** オーナーの現在のプランの公演数上限。null は無制限。 */
  eventLimit: number | null;
  /** rev の材料。application_id → applications.updated_at。 */
  updatedAtByApplicationId: Map<string, Date>;
}

export interface ShareItemHandles {
  item_key: string;
  rev: string;
  editable: boolean;
}

/**
 * 編集を許す公演 id の集合。
 * 行順（`event_date asc nulls last, event_name asc` — TourMatrixService の並び）で
 * distinct な公演を取り、先頭 N 件だけを返す。同一公演の複数申込は 1 公演。
 */
export function resolveEditableEventIds(
  rows: TourMatrixInternalRow[],
  eventLimit: number | null,
): Set<string> {
  const ordered: string[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    if (seen.has(row.event_id)) continue;
    seen.add(row.event_id);
    ordered.push(row.event_id);
  }
  if (eventLimit === null) return seen;
  return new Set(ordered.slice(0, Math.max(eventLimit, 0)));
}

/**
 * 行 → ハンドル の変換関数を作る（公演順の評価は 1 回で済ませる）。
 *
 * `editable` は次の 2 条件を**両方**満たすときだけ true:
 * ①代表名義の `history_visible` が true ②その公演が先頭 N 件以内。
 * **どちらで false になったかは戻り値から区別できない**（オーナーの課金状態を漏らさない）。
 */
export function createShareItemAnnotator(
  rows: TourMatrixInternalRow[],
  context: ShareWriteContext,
): (row: TourMatrixInternalRow) => ShareItemHandles {
  const editableEventIds = resolveEditableEventIds(rows, context.eventLimit);

  return (row) => ({
    item_key: shareItemKey(context.tokenHash, row.application_id),
    rev: shareItemRev(
      context.tokenHash,
      row.application_id,
      requireUpdatedAt(context, row.application_id),
    ),
    editable: row.rep_history_visible && editableEventIds.has(row.event_id),
  });
}

/**
 * updated_at が無いのは matrix 取得と updated_at 取得の間で行が消えた場合だけ。
 * 偽の rev を返して黙って壊すより 500 にする（BE-2）。内部 id は message に出さない。
 */
function requireUpdatedAt(
  context: ShareWriteContext,
  applicationId: string,
): Date {
  const updatedAt = context.updatedAtByApplicationId.get(applicationId);
  if (!updatedAt) {
    throw new AppError(
      ErrorCode.INTERNAL,
      'shared item revision is unavailable',
    );
  }
  return updatedAt;
}
