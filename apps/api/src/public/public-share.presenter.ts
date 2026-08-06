import { SharePermission } from '../shares/dto/create-share.dto';
import { TourMatrixInternalRow } from '../tours/tour-matrix.service';
import { IdentitySummaryRow } from './identity-summary.service';
import {
  ShareItemHandles,
  ShareWriteContext,
  createShareItemAnnotator,
} from './share-write';

/**
 * **公開ペイロードのマスキングはこのファイルに集約する** (FR-SH-9 / FR-SH-10 / BE-4)。
 *
 * 不変条件:
 * 1. 入力行を spread しない。契約のキーだけを明示的に組み立てる
 * 2. 会員番号・owner_id・account_id・shared_with_account_ids・内部 UUID
 *    (identity_id / application_id / event_id / tour_id) を一切出さない
 * 3. `history_visible = false` の名義は
 *    tour スコープ: rep_name をマスク・rep_color / seat を null
 *    identity_summary スコープ: visible:false とし件数キー自体を出さない
 * 4. `item_key` / `rev` / `editable` は `permission:"write"` の tour スコープにだけ付く。
 *    read リンクのペイロードには 1 つも現れない（api-contract-delta.md §4）。
 *    3 キーの**計算そのものは share-write.ts** に分離してある
 */

/** history_visible=false の名義の表示名（E-11）。 */
export const MASKED_IDENTITY_NAME = '非公開の名義';

export interface TourShareItem {
  event_name: string;
  venue: string | null;
  event_date: string | null;
  round_name: string | null;
  rep_name: string;
  rep_color: string | null;
  companions: string[];
  status: string;
  seat: string | null;
}

/** write リンクの item（read リンクには現れない 3 キーが増える）。 */
export interface TourShareWriteItem extends TourShareItem {
  item_key: string;
  rev: string;
  editable: boolean;
}

export interface TourSharePayload {
  scope_type: 'tour';
  permission: SharePermission;
  tour: { name: string; artist_name: string | null };
  generated_at: string;
  items: TourShareItem[];
}

/** read は追加情報なし。write は HMAC の鍵・プラン上限・updated_at を要求する。 */
export type TourShareRenderOptions =
  { permission: 'read' } | { permission: 'write'; write: ShareWriteContext };

export interface IdentitySummaryVisibleItem {
  name: string;
  visible: true;
  application_count: number;
  won_count: number;
}

export interface IdentitySummaryHiddenItem {
  name: string;
  visible: false;
}

export type IdentitySummaryItem =
  IdentitySummaryVisibleItem | IdentitySummaryHiddenItem;

export interface IdentitySummaryPayload {
  scope_type: 'identity_summary';
  /** identity_summary は常に read（書き込みは tour スコープのみ）。 */
  permission: 'read';
  generated_at: string;
  items: IdentitySummaryItem[];
}

export type PublicSharePayload = TourSharePayload | IdentitySummaryPayload;

/** 公開に出してよい tour の情報だけを受ける（owner_id / id は受け取らない）。 */
export interface SharedTourLike {
  name: string;
  artistNameRaw: string | null;
}

export function toTourSharePayload(
  tour: SharedTourLike,
  rows: TourMatrixInternalRow[],
  generatedAt: Date,
  options: TourShareRenderOptions = { permission: 'read' },
): TourSharePayload {
  // read リンクでは annotator を作らない（3 キーが混入する経路自体を作らない）
  const annotate =
    options.permission === 'write'
      ? createShareItemAnnotator(rows, options.write)
      : null;

  return {
    scope_type: 'tour',
    permission: options.permission,
    tour: { name: tour.name, artist_name: tour.artistNameRaw },
    generated_at: generatedAt.toISOString(),
    // application 0 件でも 200 + items: [] を返す（E-10 / AC-SH-17）
    items: rows.map((row) =>
      annotate
        ? toTourShareWriteItem(row, annotate(row))
        : toTourShareItem(row),
    ),
  };
}

/** write リンクの item 1 件。マスキングは read と完全に同一（3 キーを足すだけ）。 */
export function toTourShareWriteItem(
  row: TourMatrixInternalRow,
  handles: ShareItemHandles,
): TourShareWriteItem {
  return {
    ...toTourShareItem(row),
    item_key: handles.item_key,
    rev: handles.rev,
    editable: handles.editable,
  };
}

function toTourShareItem(row: TourMatrixInternalRow): TourShareItem {
  const visible = row.rep_history_visible;
  return {
    event_name: row.event_name,
    venue: row.venue_name,
    event_date: row.event_date,
    round_name: row.round_name,
    // 非公開名義は名前・色・座席を伏せる（座席は名義の特定につながるため）
    rep_name: visible ? row.rep_name : MASKED_IDENTITY_NAME,
    rep_color: visible ? row.rep_color : null,
    // 同行者は identity_id があればその現在の display_name（matrix で解決済み）
    companions: [...row.companion_names],
    status: row.status,
    seat: visible ? row.seat_raw : null,
  };
}

export function toIdentitySummaryPayload(
  rows: IdentitySummaryRow[],
  generatedAt: Date,
): IdentitySummaryPayload {
  return {
    scope_type: 'identity_summary',
    permission: 'read',
    generated_at: generatedAt.toISOString(),
    items: rows.map(toIdentitySummaryItem),
  };
}

function toIdentitySummaryItem(row: IdentitySummaryRow): IdentitySummaryItem {
  // visible:false は件数キー自体を含めない（undefined でも置かない — D10 / AC-SH-18）
  if (!row.historyVisible) {
    return { name: row.displayName, visible: false };
  }
  return {
    name: row.displayName,
    visible: true,
    application_count: row.applicationCount,
    won_count: row.wonCount,
  };
}
