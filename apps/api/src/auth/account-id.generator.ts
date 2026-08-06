import { Injectable } from '@nestjs/common';
import { randomInt } from 'node:crypto';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';

/** アカウント ID の書式（api-contract.md §8 の `shared_with_account_ids` と同じ）。 */
export const ACCOUNT_ID_PATTERN = /^ACC-[0-9A-F]{6}$/;

/** 採番の再試行回数上限（E-15）。 */
export const ACCOUNT_ID_MAX_ATTEMPTS = 5;

const HEX_DIGITS = '0123456789ABCDEF';
const ACCOUNT_ID_LENGTH = 6;

/**
 * `profiles.account_id`（`ACC-XXXXXX`）の採番。
 * ユニーク制約は DB 側が正なので、衝突したら別の値で作り直す。
 */
@Injectable()
export class AccountIdGenerator {
  generate(): string {
    let suffix = '';
    for (let i = 0; i < ACCOUNT_ID_LENGTH; i += 1) {
      suffix += HEX_DIGITS[randomInt(HEX_DIGITS.length)];
    }
    return `ACC-${suffix}`;
  }

  /**
   * 採番した account_id で persist を試み、account_id のユニーク制約違反なら
   * 別の値で最大 ACCOUNT_ID_MAX_ATTEMPTS 回まで再試行する（E-15）。
   * それ以外の例外はそのまま呼び出し元へ送出する。
   */
  async issue<T>(persist: (accountId: string) => Promise<T>): Promise<T> {
    for (let attempt = 1; attempt <= ACCOUNT_ID_MAX_ATTEMPTS; attempt += 1) {
      const accountId = this.generate();
      try {
        return await persist(accountId);
      } catch (error) {
        if (!isAccountIdUniqueViolation(error)) throw error;
      }
    }

    throw new AppError(
      ErrorCode.INTERNAL,
      'failed to allocate a unique account_id',
      { attempts: ACCOUNT_ID_MAX_ATTEMPTS },
    );
  }
}

/** Prisma のユニーク制約違反 (P2002) が account_id 由来かどうか。 */
function isAccountIdUniqueViolation(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false;
  const { code, meta } = error as {
    code?: unknown;
    meta?: { target?: unknown };
  };
  if (code !== 'P2002') return false;

  const target = meta?.target;
  const fields = Array.isArray(target)
    ? target.map((field) => String(field))
    : typeof target === 'string'
      ? [target]
      : [];
  // target が取れない場合は判別できないため再試行側に倒す
  if (fields.length === 0) return true;
  // Prisma のバージョン差 (accountId / account_id / profiles_account_id_key) を吸収する
  return fields
    .map((field) => field.toLowerCase().replace(/_/g, ''))
    .some((field) => field.includes('accountid'));
}
