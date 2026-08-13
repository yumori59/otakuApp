/**
 * throttler の tracker（キー抽出）純粋関数群。
 * IP は使わない（Cloud Run の X-Forwarded-For は詐称可能なため）。
 */

interface RequestWithBody {
  body?: { email?: unknown };
}

interface RequestWithUser {
  user?: { id?: unknown };
}

interface RequestWithUserAndShareId {
  user?: { id?: unknown };
  params?: { id?: unknown };
}

/** body.email を trim + 小文字化して返す。無ければ空文字。 */
export function emailTracker(req: RequestWithBody): string {
  const raw = req?.body?.email;
  return typeof raw === 'string' ? raw.trim().toLowerCase() : '';
}

/** JwtAuthGuard が設定した req.user.id を返す。無ければ空文字。 */
export function userTracker(req: RequestWithUser): string {
  const id = req?.user?.id;
  return typeof id === 'string' ? id : '';
}

/**
 * `req.user.id` + `req.params.id`（共有 ID）を `:` で連結して返す。
 * `share-write` の招待制化（token が req に現れなくなる）に伴うカウント単位
 * （api-contract-delta.md §0.3）。どちらかが欠けても空文字にはせず、
 * 揃った要素だけで連結する（JwtAuthGuard 済み前提なので userId は必ずある）。
 */
export function userShareTracker(req: RequestWithUserAndShareId): string {
  const userId = req?.user?.id;
  const shareId = req?.params?.id;
  const userPart = typeof userId === 'string' ? userId : '';
  const sharePart = typeof shareId === 'string' ? shareId : '';
  return `${userPart}:${sharePart}`;
}
