/** docs/04-api.md §4 — 同期対象コレクション。 */
export const SYNC_COLLECTIONS = [
  'identities',
  'memberships',
  'tours',
  'events',
  'applications',
  'application_companions',
] as const;

export type SyncCollection = (typeof SYNC_COLLECTIONS)[number];

export const SYNC_PULL_LIMIT = 500;

export function isSyncCollection(value: string): value is SyncCollection {
  return (SYNC_COLLECTIONS as readonly string[]).includes(value);
}

/** API コレクション名 → Prisma delegate 名。 */
export const SYNC_PRISMA_DELEGATE: Record<
  SyncCollection,
  | 'identity'
  | 'membership'
  | 'tour'
  | 'event'
  | 'application'
  | 'applicationCompanion'
> = {
  identities: 'identity',
  memberships: 'membership',
  tours: 'tour',
  events: 'event',
  applications: 'application',
  application_companions: 'applicationCompanion',
};
