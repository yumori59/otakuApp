import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * 共有リンク（write）の item ハンドル生成（api-contract-delta.md §4）。
 *
 * 鍵は `share_links.token_hash`（= `sha256Hex(token)`）。**秘密鍵ではない** — トークンを知っている
 * リンク保持者は自分で同じ値を計算できる。ここでの安全性は「メッセージ側（application.id という
 * 122bit の内部 UUID）が第三者から推測不能」であることに依存している。したがって `hmacBase64url`
 * を将来「推測可能なメッセージ」に転用しないこと（`item_key`/`rev` が偽造可能になる）。
 * 新しい秘密鍵の env を増やさずに「リンクごとに異なる不透明ハンドル」を作るための設計。
 *
 * 不変条件:
 * 1. `item_key` / `rev` から application の内部 UUID・`updated_at` を復元できない
 * 2. 同じ application でもリンク（token_hash）が違えば `item_key` は異なる
 * 3. 照合は長さ一致チェック + `timingSafeEqual`（長さ不一致は例外にせず false）
 */

/** base64url 22 文字（HMAC-SHA256 43 文字の先頭）。 */
export const ITEM_KEY_LENGTH = 22;
/** base64url 16 文字。 */
export const ITEM_REV_LENGTH = 16;

function hmacBase64url(tokenHash: string, message: string): string {
  return createHmac('sha256', tokenHash)
    .update(message, 'utf8')
    .digest('base64url');
}

/** `hmac_sha256(token_hash, "item:" + application_id)` の先頭 22 文字。 */
export function shareItemKey(tokenHash: string, applicationId: string): string {
  return hmacBase64url(tokenHash, `item:${applicationId}`).slice(
    0,
    ITEM_KEY_LENGTH,
  );
}

/** `hmac_sha256(token_hash, "rev:" + application_id + ":" + updated_at)` の先頭 16 文字。 */
export function shareItemRev(
  tokenHash: string,
  applicationId: string,
  updatedAt: Date,
): string {
  return hmacBase64url(
    tokenHash,
    `rev:${applicationId}:${updatedAt.toISOString()}`,
  ).slice(0, ITEM_REV_LENGTH);
}

/** ハンドル照合。長さ差・型違いで例外にせず false を返す。 */
export function handleEquals(expected: string, actual: unknown): boolean {
  if (typeof actual !== 'string' || actual.length === 0) return false;
  const a = Buffer.from(expected, 'utf8');
  const b = Buffer.from(actual, 'utf8');
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}
