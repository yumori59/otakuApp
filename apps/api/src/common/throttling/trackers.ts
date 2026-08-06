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

interface RequestWithParams {
  params?: { token?: unknown };
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

/** req.params.token を返す。無ければ空文字。 */
export function tokenTracker(req: RequestWithParams): string {
  const token = req?.params?.token;
  return typeof token === 'string' ? token : '';
}
