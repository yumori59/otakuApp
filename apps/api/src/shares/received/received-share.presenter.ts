import { SharePermission, ShareScopeType } from '../dto/create-share.dto';
import { InboxRow } from './share-recipient-access.service';

/** `scope_type = "identity_summary"` の固定表示名（api-contract-delta.md §4.1）。 */
export const IDENTITY_SUMMARY_SCOPE_NAME = '名義の申込サマリー';

export interface ReceivedInboxOwner {
  account_id: string | null;
  display_name: string | null;
}

/**
 * `GET /v1/shares/received` の 1 件（api-contract-delta.md §4.1）。
 * token / token_hash / scope_id / オーナーの内部 UUID / 他の招待者の ACC-ID /
 * 会員番号 / 申込の中身は一切含めない — キーを明示的に組み立てる（入力を spread しない）。
 */
export interface ReceivedInboxItem {
  share_id: string;
  scope_type: ShareScopeType;
  scope_name: string | null;
  permission: SharePermission;
  owner: ReceivedInboxOwner;
  invited_at: string;
  expires_at: string | null;
  unread: boolean;
}

export function toReceivedInboxItem(
  row: InboxRow,
  tourNames: Map<string, string>,
): ReceivedInboxItem {
  const link = row.shareLink;
  return {
    share_id: link.id,
    scope_type: link.scopeType as ShareScopeType,
    scope_name: resolveScopeName(link, tourNames),
    permission: link.permission as SharePermission,
    owner: {
      account_id: link.owner.profile?.accountId ?? null,
      display_name: link.owner.profile?.displayName ?? null,
    },
    invited_at: row.createdAt.toISOString(),
    expires_at: link.expiresAt ? link.expiresAt.toISOString() : null,
    // last_viewed_at is null || last_viewed_at < share_links.updated_at（api-contract-delta.md §4.1）
    unread:
      row.lastViewedAt === null || row.lastViewedAt.getTime() < link.updatedAt.getTime(),
  };
}

function resolveScopeName(
  link: InboxRow['shareLink'],
  tourNames: Map<string, string>,
): string | null {
  if (link.scopeType === 'identity_summary') return IDENTITY_SUMMARY_SCOPE_NAME;
  if (link.scopeType === 'tour' && link.scopeId) {
    return tourNames.get(link.scopeId) ?? null;
  }
  return null;
}
