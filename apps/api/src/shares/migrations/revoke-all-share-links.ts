/**
 * share-account-invites の移行（api-contract-delta.md §0.5 / Q9=9-3）。
 *
 * 共有が「トークンを知っていれば誰でも」から「招待されたアカウントだけ」に変わるため、
 * 移行前に発行された共有リンクは **全件失効させる**（backfill はしない）。
 *
 * `db push` の後に 1 回だけ実行する:
 *   cd apps/api && npm run migrate:revoke-all-shares
 */

/**
 * 失効 SQL。`where revoked_at is null` があるので **2 回実行しても
 * 既に立っている revoked_at を上書きしない**（AC-SI-62）。
 */
export const REVOKE_ALL_SHARE_LINKS_SQL =
  'update share_links set revoked_at = now() where revoked_at is null';

/**
 * 1 行に対する移行後の `revoked_at`（純粋関数 / 上の SQL の意味論そのもの）。
 * 既に失効している行は現在値を保つ（冪等 — AC-SI-62）。
 */
export function revokedAtAfterMigration(
  currentRevokedAt: Date | null,
  now: Date,
): Date {
  return currentRevokedAt ?? now;
}

/** 移行の対象行（未失効のみ）。2 回目の実行では空になる。 */
export function shareLinksToRevoke<T extends { revokedAt: Date | null }>(
  rows: readonly T[],
): T[] {
  return rows.filter((row) => row.revokedAt === null);
}
