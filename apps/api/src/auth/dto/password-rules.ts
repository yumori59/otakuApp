import { Transform } from 'class-transformer';

/** パスワードの長さ（api-contract-delta.md §1）。文字種の複雑さ要件は無い。 */
export const PASSWORD_MIN_LENGTH = 8;
export const PASSWORD_MAX_LENGTH = 128;

/** email の最大長（DTO 共通）。 */
export const EMAIL_MAX_LENGTH = 255;

/**
 * login のパスワードにだけ使う上限。
 * 旧ポリシーのユーザーを弾かないよう下限は掛けず、DoS 避けの上限だけ持つ。
 */
export const LOGIN_PASSWORD_MAX_LENGTH = 1024;

/**
 * email の前後空白を落としてから検証する。
 * `@IsEmail()` は前後空白を不正と見なすため、これが無いと
 * `"Fan@Example.com "` が 400 になる（AC-EP-03）。
 */
export const TrimEmail = () =>
  Transform(({ value }: { value: unknown }) =>
    typeof value === 'string' ? value.trim() : value,
  );

/** `email_normalized` に保存する値（AC-EP-03）。 */
export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}
