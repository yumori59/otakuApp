/**
 * api-contract.md §0 の application status。
 * この値以外は 400。黙って `applied` などに落とさない（BE-2 / FR-AP-7）。
 */
export const APPLICATION_STATUSES = [
  'draft',
  'applied',
  'won',
  'lost',
  'cancelled',
] as const;

export type ApplicationStatus = (typeof APPLICATION_STATUSES)[number];

/** status 省略時の既定値（api-contract.md §7）。 */
export const DEFAULT_APPLICATION_STATUS: ApplicationStatus = 'applied';
