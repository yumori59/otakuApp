/** 有効判定に必要な最小の形（ShareLink 行 / テスト用ダミーの双方を受ける）。 */
export interface ShareLinkValidity {
  revokedAt: Date | null;
  expiresAt: Date | null;
}

/**
 * 共有リンクが有効か。`revoked_at is null && (expires_at is null || expires_at > now)`。
 * **期限ちょうど（expires_at === now）は無効**（api-contract.md §8 / E-8）。
 * GET /v1/shares の is_active と公開解決の可否は同じ判定を使う。
 */
export function isShareActive(
  link: ShareLinkValidity,
  now: Date = new Date(),
): boolean {
  if (link.revokedAt !== null) return false;
  if (link.expiresAt === null) return true;
  return link.expiresAt.getTime() > now.getTime();
}
