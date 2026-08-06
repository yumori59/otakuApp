import { Logger } from '@nestjs/common';
import { KeyObject, createPublicKey } from 'node:crypto';

/** id_token の kid から発行者の公開鍵を解決する（Apple / Google 共通）。 */
export abstract class JwksProvider {
  abstract getPublicKey(kid: string): Promise<KeyObject | null>;
}

interface Rs256Jwk {
  kty?: unknown;
  kid?: unknown;
  alg?: unknown;
  use?: unknown;
  n?: unknown;
  e?: unknown;
}

/** JWKS のキャッシュ有効期間。Apple / Google の鍵ローテーションは低頻度。 */
export const JWKS_CACHE_TTL_MS = 60 * 60 * 1000;
/** JWKS 取得のタイムアウト。 */
export const JWKS_FETCH_TIMEOUT_MS = 5000;
/**
 * 未知 kid による強制再取得の cooldown（jose の `createRemoteJWKSet` 既定と同じ 30s）。
 * これが無いと、未認証の攻撃者がランダム kid の JWT を投げ続けるだけで
 * リクエストごとに外向き fetch を強制できる。
 */
export const FORCED_FETCH_COOLDOWN_MS = 30 * 1000;

/**
 * リモート JWKS を取得してキャッシュする基底クラス。
 * 未知の kid を要求されたときだけキャッシュを捨てて再取得する（鍵ローテーション対応）。
 * ただし強制再取得は cooldown で 30 秒に 1 回までに制限する。
 */
export abstract class RemoteJwksProvider extends JwksProvider {
  private readonly logger = new Logger(this.constructor.name);
  private cache: Map<string, KeyObject> | null = null;
  private cachedAt = 0;
  private lastForcedFetchAt = 0;
  private inflight: Promise<Map<string, KeyObject>> | null = null;

  /** JWKS の取得先 URL（env から解決する）。 */
  protected abstract jwksUrl(): string;
  /** ログに出す発行者名（例: `Apple`）。 */
  protected abstract get issuerLabel(): string;

  async getPublicKey(kid: string): Promise<KeyObject | null> {
    const cached = await this.keys(false);
    const hit = cached.get(kid);
    if (hit) return hit;

    // 未知 kid はローテーション直後の可能性があるので強制再取得する。
    // cooldown 中はキャッシュだけで判断し、見つからなければ検証失敗（401）にする。
    const now = Date.now();
    if (now - this.lastForcedFetchAt < FORCED_FETCH_COOLDOWN_MS) return null;
    this.lastForcedFetchAt = now;

    const refreshed = await this.keys(true);
    return refreshed.get(kid) ?? null;
  }

  private async keys(force: boolean): Promise<Map<string, KeyObject>> {
    const fresh = Date.now() - this.cachedAt < JWKS_CACHE_TTL_MS;
    if (!force && this.cache && fresh) return this.cache;
    if (this.inflight) return this.inflight;

    this.inflight = this.fetchKeys()
      .then((keys) => {
        this.cache = keys;
        this.cachedAt = Date.now();
        return keys;
      })
      .catch((error: unknown) => {
        this.logger.error(
          `failed to fetch ${this.issuerLabel} JWKS`,
          error instanceof Error ? error.stack : String(error),
        );
        // 取得失敗時は古いキャッシュで検証を続ける（無ければ空 = 検証失敗）
        return this.cache ?? new Map<string, KeyObject>();
      })
      .finally(() => {
        this.inflight = null;
      });

    return this.inflight;
  }

  private async fetchKeys(): Promise<Map<string, KeyObject>> {
    const res = await fetch(this.jwksUrl(), {
      signal: AbortSignal.timeout(JWKS_FETCH_TIMEOUT_MS),
    });
    if (!res.ok) {
      throw new Error(`${this.issuerLabel} JWKS responded ${res.status}`);
    }

    const body = (await res.json()) as { keys?: Rs256Jwk[] };
    const keys = new Map<string, KeyObject>();
    for (const jwk of body?.keys ?? []) {
      const key = toPublicKey(jwk);
      if (key) keys.set(String(jwk.kid), key);
    }
    return keys;
  }
}

/** 受理するのは RS256 の RSA 公開鍵のみ。それ以外は無視する。 */
function toPublicKey(jwk: Rs256Jwk): KeyObject | null {
  if (jwk?.kty !== 'RSA' || typeof jwk.kid !== 'string') return null;
  if (typeof jwk.n !== 'string' || typeof jwk.e !== 'string') return null;
  if (jwk.alg !== undefined && jwk.alg !== 'RS256') return null;

  try {
    return createPublicKey({
      key: { kty: 'RSA', n: jwk.n, e: jwk.e },
      format: 'jwk',
    });
  } catch {
    return null;
  }
}
