import { createHash, randomBytes } from 'node:crypto';

/** refresh token / share token の保存用ハッシュ。平文は DB に入れない。 */
export function sha256Hex(raw: string): string {
  return createHash('sha256').update(raw, 'utf8').digest('hex');
}

/** URL 安全な不透明トークンを生成する。 */
export function randomToken(bytes = 32): string {
  return randomBytes(bytes).toString('base64url');
}
