import { fromDateOnly, toDateOnly } from './date.util';

export type RenewalUrgency = 'expired' | 'warning' | 'soon' | 'ok';

/** 日付のみフィールドの正は Asia/Tokyo（docs/05 §6）。 */
export function todayJstDateString(now = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Tokyo' }).format(
    now,
  );
}

/** `YYYY-MM-DD` 同士の日数差（to − from）。 */
export function daysUntilDateOnly(fromYmd: string, toYmd: string): number {
  const from = toDateOnly(fromYmd);
  const to = toDateOnly(toYmd);
  return Math.round((to.getTime() - from.getTime()) / 86_400_000);
}

export function daysUntilRenewal(
  renewalOn: Date,
  todayYmd = todayJstDateString(),
): number {
  return daysUntilDateOnly(todayYmd, fromDateOnly(renewalOn)!);
}

/** docs/03-database.md §7.2 — モック `renewalBadge()` と同一閾値。 */
export function renewalUrgency(daysUntil: number): RenewalUrgency {
  if (daysUntil < 0) return 'expired';
  if (daysUntil <= 14) return 'warning';
  if (daysUntil <= 30) return 'soon';
  return 'ok';
}
