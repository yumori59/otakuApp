import { AppError } from '../errors/app-error';

const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * `YYYY-MM-DD` を UTC 0 時の Date にする（Prisma の @db.Date 用）。
 * サーバーのローカル TZ に依存しない（E-12）。
 */
export function toDateOnly(value: string): Date {
  if (typeof value !== 'string' || !DATE_ONLY_RE.test(value)) {
    throw AppError.validation(
      `invalid date format (expected YYYY-MM-DD): ${String(value)}`,
    );
  }
  const date = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(date.getTime()) || fromDateOnly(date) !== value) {
    throw AppError.validation(`invalid date: ${value}`);
  }
  return date;
}

/** Date を `YYYY-MM-DD`（UTC 基準）にする。null / undefined は null。 */
export function fromDateOnly(value: Date | null | undefined): string | null {
  if (value === null || value === undefined) return null;
  return value.toISOString().slice(0, 10);
}
