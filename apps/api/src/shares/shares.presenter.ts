import { ShareLink } from '@prisma/client';
import { isShareActive } from './share-validity';

/**
 * POST /v1/shares の 201 ボディ (api-contract.md §8)。
 * **生トークンを返すのは発行時のこのレスポンスだけ**。
 */
// NOTE(share-account-invites T1): `shared_with_account_ids` は share_links の列ごと削除した。
// 招待先は share_recipients が正で、レスポンスの `recipients` は T3 が足す
// （api-contract-delta.md §1 / §2）。
export interface ShareCreatedResponse {
  id: string;
  token: string;
  url: string;
  scope_type: string;
  scope_id: string | null;
  permission: string;
  mask_member_no: boolean;
  expires_at: string | null;
  created_at: string;
}

/**
 * GET /v1/shares の items 要素 (api-contract.md §8)。
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

/** `${SHARE_BASE_URL}/s/${token}`。末尾スラッシュを重複させない。 */
export function shareUrl(baseUrl: string, token: string): string {
  return `${baseUrl.replace(/\/+$/, '')}/s/${token}`;
}

export function toShareCreatedResponse(
  row: ShareLink,
  token: string,
  baseUrl: string,
): ShareCreatedResponse {
  return {
    id: row.id,
    token,
    url: shareUrl(baseUrl, token),
    scope_type: row.scopeType,
    scope_id: row.scopeId,
    permission: row.permission,
    mask_member_no: row.maskMemberNo,
    expires_at: row.expiresAt ? row.expiresAt.toISOString() : null,
    created_at: row.createdAt.toISOString(),
  };
}

export function toShareListItem(
  row: ShareLink,
  scopeName: string | null,
  now: Date,
): ShareListItemResponse {
  return {
    id: row.id,
    scope_type: row.scopeType,
    scope_id: row.scopeId,
    scope_name: scopeName,
    permission: row.permission,
    mask_member_no: row.maskMemberNo,
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
