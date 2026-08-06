import {
  KeyObject,
  timingSafeEqual,
  verify as verifySignature,
} from 'node:crypto';
import { AppError } from '../../common/errors/app-error';
import { JwksProvider } from './remote-jwks.provider';

/** OIDC の id_token に受理する唯一の署名アルゴリズム（alg 摩り替え対策）。 */
export const SUPPORTED_ALG = 'RS256';
/** RS256 = RSASSA-PKCS1-v1_5 + SHA-256。 */
const SIGNATURE_ALGORITHM = 'RSA-SHA256';

interface JwtHeader {
  alg?: unknown;
  kid?: unknown;
}

/** 署名検証後に読み出す id_token のクレーム（型は呼び出し側で絞る）。 */
export interface OidcIdTokenPayload {
  iss?: unknown;
  aud?: unknown;
  sub?: unknown;
  exp?: unknown;
  nonce?: unknown;
  email?: unknown;
  email_verified?: unknown;
}

export function decodeSegment<T>(segment: string): T | null {
  try {
    return JSON.parse(Buffer.from(segment, 'base64url').toString('utf8')) as T;
  } catch {
    return null;
  }
}

/** `header.payload.signature` に分解する。空セグメントを含むものは受理しない。 */
export function splitJwt(token: unknown): [string, string, string] | null {
  const segments = typeof token === 'string' ? token.split('.') : [];
  if (segments.length !== 3 || segments.some((s) => s.length === 0)) {
    return null;
  }
  return [segments[0], segments[1], segments[2]];
}

export function verifyRs256(
  signingInput: string,
  encodedSignature: string,
  publicKey: KeyObject,
): boolean {
  try {
    return verifySignature(
      SIGNATURE_ALGORITHM,
      Buffer.from(signingInput, 'ascii'),
      publicKey,
      Buffer.from(encodedSignature, 'base64url'),
    );
  } catch {
    return false;
  }
}

/** aud は文字列と配列のどちらもあり得る。expected はいずれか 1 つに一致すればよい。 */
export function audienceMatches(
  aud: unknown,
  expected: readonly string[],
): boolean {
  const matchesOne = (value: string) =>
    expected.some((candidate) => safeEquals(value, candidate));
  if (typeof aud === 'string') return matchesOne(aud);
  if (Array.isArray(aud)) {
    return aud.some((value) => typeof value === 'string' && matchesOne(value));
  }
  return false;
}

export function safeEquals(a: string, b: string): boolean {
  const left = Buffer.from(a, 'utf8');
  const right = Buffer.from(b, 'utf8');
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

export interface VerifyOidcIdTokenParams {
  idToken: string;
  jwks: JwksProvider;
  /** 受理する iss（いずれか 1 つに一致すればよい）。 */
  issuers: readonly string[];
  /** 受理する aud（いずれか 1 つに一致すればよい）。 */
  audiences: readonly string[];
  /** リクエストが送ってきたときのみ検証する（サーバー側でハッシュしない単純比較）。 */
  nonce?: string;
  /** 検証失敗時に投げる例外を作る（Apple / Google でコードが違う）。 */
  invalid: (message: string) => AppError;
}

/**
 * JWKS の公開鍵で id_token を検証する（Apple / Google 共通）。
 * 署名・`iss`・`aud`・`exp`・（req が nonce を送っている場合のみ）`nonce` を確認する。
 * 失敗理由は呼び出し側の `invalid` に集約し、外部には区別させない。
 */
export async function verifyOidcIdToken(
  params: VerifyOidcIdTokenParams,
): Promise<OidcIdTokenPayload> {
  const { idToken, jwks, issuers, audiences, nonce, invalid } = params;

  const segments = splitJwt(idToken);
  if (!segments) throw invalid('malformed id token');
  const [encodedHeader, encodedPayload, encodedSignature] = segments;

  const header = decodeSegment<JwtHeader>(encodedHeader);
  if (!header) throw invalid('malformed id token header');
  if (header.alg !== SUPPORTED_ALG) throw invalid('unsupported id token alg');
  if (typeof header.kid !== 'string' || header.kid.length === 0) {
    throw invalid('id token has no kid');
  }

  const publicKey = await jwks.getPublicKey(header.kid);
  if (!publicKey) throw invalid('unknown signing key');

  if (
    !verifyRs256(`${encodedHeader}.${encodedPayload}`, encodedSignature, publicKey)
  ) {
    throw invalid('id token signature verification failed');
  }

  const payload = decodeSegment<OidcIdTokenPayload>(encodedPayload);
  if (!payload) throw invalid('malformed id token payload');

  if (typeof payload.iss !== 'string' || !issuers.includes(payload.iss)) {
    throw invalid('unexpected iss');
  }
  if (!audienceMatches(payload.aud, audiences)) throw invalid('unexpected aud');

  if (typeof payload.exp !== 'number' || !Number.isFinite(payload.exp)) {
    throw invalid('id token has no exp');
  }
  if (payload.exp * 1000 <= Date.now()) throw invalid('token expired');

  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw invalid('id token has no sub');
  }

  // nonce はリクエストが送ってきたときだけ検証する
  if (nonce !== undefined) {
    if (typeof payload.nonce !== 'string' || !safeEquals(payload.nonce, nonce)) {
      throw invalid('nonce mismatch');
    }
  }

  return payload;
}
