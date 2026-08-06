import { toDateOnly } from '../common/util/date.util';
import { SyncCollection } from './sync-collections';

function parseDeletedAt(value: unknown): Date | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== 'string') return null;
  return new Date(value);
}

function parseDateOnly(value: unknown): Date | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== 'string') return null;
  return toDateOnly(value);
}

function parseOptionalIso(value: unknown): Date | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (typeof value !== 'string') return undefined;
  return new Date(value);
}

/** Push mutation の payload (snake_case) → Prisma upsert data (camelCase)。 */
export function payloadToPrismaData(
  collection: SyncCollection,
  payload: Record<string, unknown>,
): Record<string, unknown> {
  switch (collection) {
    case 'identities':
      return {
        displayName: payload.display_name,
        relation: payload.relation,
        color: payload.color,
        joinedOn: parseDateOnly(payload.joined_on),
        note: payload.note ?? null,
        historyVisible: payload.history_visible,
        sortOrder: payload.sort_order,
        deletedAt: parseDeletedAt(payload.deleted_at),
      };
    case 'memberships':
      return {
        identityId: payload.identity_id,
        fanClubNameRaw: payload.fan_club_name_raw,
        memberNoLast4: payload.member_no_last4 ?? null,
        rank: payload.rank ?? null,
        renewalOn: parseDateOnly(payload.renewal_on),
        feeYen: payload.fee_yen ?? null,
        autoRenew: payload.auto_renew ?? false,
        note: payload.note ?? null,
        deletedAt: parseDeletedAt(payload.deleted_at),
      };
    case 'tours':
      return {
        name: payload.name,
        artistNameRaw: payload.artist_name_raw ?? null,
        deletedAt: parseDeletedAt(payload.deleted_at),
      };
    case 'events':
      return {
        tourId: payload.tour_id,
        name: payload.name,
        venueNameRaw: payload.venue_name_raw ?? null,
        eventDate: parseDateOnly(payload.event_date),
        startsAt: parseOptionalIso(payload.starts_at),
        deletedAt: parseDeletedAt(payload.deleted_at),
      };
    case 'applications':
      return {
        eventId: payload.event_id,
        repIdentityId: payload.rep_identity_id,
        repMembershipId: payload.rep_membership_id ?? null,
        roundName: payload.round_name ?? null,
        appliedOn: parseDateOnly(payload.applied_on),
        resultOn: parseDateOnly(payload.result_on),
        status: payload.status,
        seatRaw: payload.seat_raw ?? null,
        ticketCount: payload.ticket_count ?? 1,
        priceYen: payload.price_yen ?? null,
        note: payload.note ?? null,
        deletedAt: parseDeletedAt(payload.deleted_at),
      };
    case 'application_companions':
      return {
        applicationId: payload.application_id,
        identityId: payload.identity_id ?? null,
        displayName: payload.display_name,
        position: payload.position ?? 0,
        deletedAt: parseDeletedAt(payload.deleted_at),
      };
    default:
      return payload;
  }
}

export function isDeletedPayload(payload: Record<string, unknown>): boolean {
  const deletedAt = payload.deleted_at;
  return deletedAt !== null && deletedAt !== undefined;
}
