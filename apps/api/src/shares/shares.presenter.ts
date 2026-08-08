import { ShareLink } from '@prisma/client';
import { isShareActive } from './share-validity';

/**
 * 招待 1 件のレスポンス形 (api-contract-delta.md §1 / §2 / §3)。
 * `hidden_at` は絶対に含めない（オーナーに受け取り側の非表示を見せない — Q3）。
 */
export interface ShareRecipientResponse {
  account_id: string;
  display_name: string | null;
  invited_at: string;
  last_viewed_at: string | null;
}

/**
 * POST /v1/shares の 201 ボディ (api-contract-delta.md §1)。
 * **生トークンを返すのは発行時のこのレスポンスだけ**。
 */
export interface ShareCreatedResponse {
  id: string;
  token: string;
  url: string;
  scope_type: string;
  scope_id: string | null;
  permission: string;
  mask_member_no: boolean;
  recipients: ShareRecipientResponse[];
  expires_at: string | null;
  created_at: string;
}

/**
 * GET /v1/shares の items 要素 (api-contract-delta.md §2)。
 * **`token` / `token_hash` を絶対に含めない**（FR-SH-6 / AC-SH-09）。
 * 行を spread せず、契約のキーだけを明示的に組み立てる。
 */
export interface ShareListItemResponse {
  id: string;
  scope_type: string;
  scope_id: string | null;
  scope_name: string | null;
  permission: string;
  mask_member_no: boolean;
  recipients: ShareRecipientResponse[];
  expires_at: string | null;
  revoked_at: string | null;
  view_count: number;
  last_viewed_at: string | null;
  /** 共有先による編集回数（api-contract-delta.md §3 / E6）。既定 0。 */
  edit_count: number;
  last_edited_at: string | null;
  created_at: string;
  is_active: boolean;
}

/**
 * `meigicho://share/<token>`（api-contract-delta.md D9）。
 * `/public/*` 廃止により https の URL は開ける先が無いため、カスタムスキームに固定する。
 * `SHARE_BASE_URL` のような環境変数には依存しない。
 */
const SHARE_URL_SCHEME = 'meigicho://share/';

export function shareUrl(token: string): string {
  return `${SHARE_URL_SCHEME}${token}`;
}

export function toShareCreatedResponse(
  row: ShareLink,
  token: string,
  recipients: ShareRecipientResponse[],
): ShareCreatedResponse {
  return {
    id: row.id,
    token,
    url: shareUrl(token),
    scope_type: row.scopeType,
    scope_id: row.scopeId,
    permission: row.permission,
    mask_member_no: row.maskMemberNo,
    recipients,
    expires_at: row.expiresAt ? row.expiresAt.toISOString() : null,
    created_at: row.createdAt.toISOString(),
  };
}

export function toShareListItem(
  row: ShareLink,
  scopeName: string | null,
  recipients: ShareRecipientResponse[],
  now: Date,
): ShareListItemResponse {
  return {
    id: row.id,
    scope_type: row.scopeType,
    scope_id: row.scopeId,
    scope_name: scopeName,
    permission: row.permission,
    mask_member_no: row.maskMemberNo,
    recipients,
    expires_at: row.expiresAt ? row.expiresAt.toISOString() : null,
    revoked_at: row.revokedAt ? row.revokedAt.toISOString() : null,
    view_count: row.viewCount,
    last_viewed_at: row.lastViewedAt ? row.lastViewedAt.toISOString() : null,
    edit_count: row.editCount,
    last_edited_at: row.lastEditedAt ? row.lastEditedAt.toISOString() : null,
    created_at: row.createdAt.toISOString(),
    is_active: isShareActive(row, now),
  };
}
