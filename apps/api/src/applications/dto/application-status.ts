/**
 * api-contract.md §0 の application status。
 * この値以外は 400。黙って `applied` などに落とさない（BE-2 / FR-AP-7）。
 */
export const APPLICATION_STATUSES = [
  'draft',
  'applied',
  'won',
  'won_unpaid', // 当選・未入金（当選として集計する）
  'lost',
  'cancelled',
] as const;

export type ApplicationStatus = (typeof APPLICATION_STATUSES)[number];

/**
 * 「当選」として集計する status（won_count・当選率の decided）。
 * `applied` のみが「発表待ち」。
 */
export const WON_STATUSES: readonly ApplicationStatus[] = ['won', 'won_unpaid'];

export function isWonStatus(status: string): boolean {
  return (WON_STATUSES as readonly string[]).includes(status);
}

/** status 省略時の既定値（api-contract.md §7）。 */
export const DEFAULT_APPLICATION_STATUS: ApplicationStatus = 'applied';
