import { randomInt } from 'node:crypto';
import { sha256Hex } from '../common/util/hash.util';

/** リセットコードの有効期間（分）。コード定数（env を増やさない）。 */
export const RESET_CODE_TTL_MINUTES = 15;
/** 同一コードに対して許す誤り回数。超えたらそのコードを失効させる。 */
export const RESET_CODE_MAX_ATTEMPTS = 5;
/** 8 桁の数字（先頭 0 を許す）。DTO の @Matches と同じ値を使う。 */
export const RESET_CODE_PATTERN = /^\d{8}$/;

const CODE_DIGITS = 8;

/** 8 桁の数字コードを生成する（先頭 0 を許すため文字列で組み立てる）。 */
export function generateResetCode(): string {
  let code = '';
  for (let i = 0; i < CODE_DIGITS; i += 1) code += String(randomInt(10));
  return code;
}

/**
 * DB に保存するコードのハッシュ。平文コードは保存しない（AC-PR-04）。
 * userId を混ぜることでユーザーをまたいだ衝突・総当たりを避ける。
 */
export function resetCodeHash(userId: string, code: string): string {
  return sha256Hex(`${userId}:${code}`);
}
