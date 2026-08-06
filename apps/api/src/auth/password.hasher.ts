import { Inject, Injectable, Optional } from '@nestjs/common';
import { randomBytes, scrypt, timingSafeEqual } from 'node:crypto';

/** promisify だと maxmem 付きのオーバーロードを拾えないので手で包む。 */
function scryptAsync(
  password: string,
  salt: Buffer,
  keylen: number,
  options: { N: number; r: number; p: number; maxmem: number },
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, keylen, options, (error, derived) => {
      if (error) reject(error);
      else resolve(derived);
    });
  });
}

export interface ScryptParams {
  /** CPU / メモリコスト。2 のべき乗。 */
  N: number;
  /** ブロックサイズ。 */
  r: number;
  /** 並列度。 */
  p: number;
}

/** 現行の既定パラメータ（plan.md §4.3）。変更したら needsRehash が true になる。 */
export const SCRYPT_DEFAULT_PARAMS: ScryptParams = { N: 32768, r: 8, p: 3 };

/**
 * パラメータ差し替え用の任意 DI トークン。
 * 未提供なら SCRYPT_DEFAULT_PARAMS を使う（spec は `new` で直接渡す）。
 */
export const SCRYPT_PARAMS = Symbol('SCRYPT_PARAMS');

const ALGORITHM = 'scrypt';
const SALT_BYTES = 16;
const KEY_BYTES = 32;

/**
 * パスワードハッシュの DI トークン兼インターフェース。
 * `AppleTokenVerifier` と同じ形で、spec は軽いスタブに差し替えられる。
 */
export abstract class PasswordHasher {
  abstract hash(plain: string): Promise<string>;
  /**
   * 保存済みハッシュと平文を比較する。
   * `stored` が null / 壊れていても**必ずハッシュ計算を 1 回行ってから** false を返す
   * （ユーザーの存在有無をタイミングで漏らさない — AC-EP-09）。
   */
  abstract verify(plain: string, stored: string | null): Promise<boolean>;
  /** 保存済みハッシュが現行の既定パラメータで作られていないか。 */
  abstract needsRehash(stored: string | null): boolean;
}

interface ParsedHash {
  params: ScryptParams;
  salt: Buffer;
  key: Buffer;
}

/**
 * node:crypto の scrypt によるパスワードハッシュ（新規 npm 依存を増やさない）。
 * 形式: `scrypt$N=32768,r=8,p=3$<salt(base64url)>$<hash(base64url)>`
 */
@Injectable()
export class ScryptPasswordHasher extends PasswordHasher {
  private readonly params: ScryptParams;

  constructor(@Optional() @Inject(SCRYPT_PARAMS) params?: ScryptParams) {
    super();
    this.params = params ?? SCRYPT_DEFAULT_PARAMS;
  }

  async hash(plain: string): Promise<string> {
    const salt = randomBytes(SALT_BYTES);
    const key = await this.derive(plain, salt, this.params);
    return [
      ALGORITHM,
      formatParams(this.params),
      salt.toString('base64url'),
      key.toString('base64url'),
    ].join('$');
  }

  async verify(plain: string, stored: string | null): Promise<boolean> {
    const parsed = parseHash(stored);
    // 未登録・パスワード未設定でもダミーで同じ計算量を消費する（AC-EP-09）
    const target = parsed ?? {
      params: this.params,
      salt: DUMMY_SALT,
      key: DUMMY_KEY,
    };

    const key = await this.derive(plain, target.salt, target.params);
    if (key.length !== target.key.length) return false;
    const matched = timingSafeEqual(key, target.key);
    return parsed !== null && matched;
  }

  needsRehash(stored: string | null): boolean {
    const parsed = parseHash(stored);
    if (!parsed) return true;
    return (
      parsed.params.N !== this.params.N ||
      parsed.params.r !== this.params.r ||
      parsed.params.p !== this.params.p
    );
  }

  private derive(
    plain: string,
    salt: Buffer,
    params: ScryptParams,
  ): Promise<Buffer> {
    return scryptAsync(plain, salt, KEY_BYTES, {
      N: params.N,
      r: params.r,
      p: params.p,
      // 既定の maxmem (32MB) では N=32768,r=8,p=3 が通らないので明示する
      maxmem: 128 * params.N * params.r * params.p + 1024 * 1024,
    });
  }
}

/** ユーザー不在時に使うダミー。値そのものに意味は無い（照合は必ず失敗させる）。 */
const DUMMY_SALT = Buffer.alloc(SALT_BYTES, 0);
const DUMMY_KEY = Buffer.alloc(KEY_BYTES, 0);

function formatParams(params: ScryptParams): string {
  return `N=${params.N},r=${params.r},p=${params.p}`;
}

function parseHash(stored: string | null): ParsedHash | null {
  if (typeof stored !== 'string' || stored.length === 0) return null;

  const segments = stored.split('$');
  if (segments.length !== 4) return null;
  const [algorithm, rawParams, rawSalt, rawKey] = segments;
  if (algorithm !== ALGORITHM) return null;

  const params = parseParams(rawParams);
  if (!params) return null;

  const salt = Buffer.from(rawSalt, 'base64url');
  const key = Buffer.from(rawKey, 'base64url');
  if (salt.length === 0 || key.length === 0) return null;

  return { params, salt, key };
}

function parseParams(raw: string): ScryptParams | null {
  const matched = /^N=(\d+),r=(\d+),p=(\d+)$/.exec(raw);
  if (!matched) return null;

  const N = Number(matched[1]);
  const r = Number(matched[2]);
  const p = Number(matched[3]);
  if (N <= 1 || r <= 0 || p <= 0) return null;
  // 2 のべき乗でない N は scrypt がエラーにするので、ここで弾いて例外化させない
  if ((N & (N - 1)) !== 0) return null;

  return { N, r, p };
}
