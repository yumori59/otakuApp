import { fromDateOnly } from '../common/util/date.util';

function iso(value: Date | null | undefined): string | null {
  return value ? value.toISOString() : null;
}

/** Pull レスポンス用 — Prisma 行を snake_case に直す。 */
export function serializeSyncRecord(
  collection: string,
  row: Record<string, unknown>,
): Record<string, unknown> {
  switch (collection) {
    case 'identities':
      return {
        id: row.id,
        owner_id: row.ownerId,
        display_name: row.displayName,
        relation: row.relation,
        color: row.color,
        joined_on: fromDateOnly(row.joinedOn as Date | null),
        note: row.note,
        history_visible: row.historyVisible,
        sort_order: row.sortOrder,
        created_at: iso(row.createdAt as Date),
        updated_at: iso(row.updatedAt as Date),
        deleted_at: iso(row.deletedAt as Date | null | undefined),
      };
    case 'memberships':
      return {
        id: row.id,
        owner_id: row.ownerId,
        identity_id: row.identityId,
        fan_club_name_raw: row.fanClubNameRaw,
        member_no: row.memberNo,
        rank: row.rank,
        renewal_on: fromDateOnly(row.renewalOn as Date | null),
        fee_yen: row.feeYen,
        auto_renew: row.autoRenew,
        note: row.note,
        created_at: iso(row.createdAt as Date),
        updated_at: iso(row.updatedAt as Date),
        deleted_at: iso(row.deletedAt as Date | null | undefined),
      };
    case 'tours':
      return {
        id: row.id,
        owner_id: row.ownerId,
        artist_name_raw: row.artistNameRaw,
        name: row.name,
        created_at: iso(row.createdAt as Date),
        updated_at: iso(row.updatedAt as Date),
        deleted_at: iso(row.deletedAt as Date | null | undefined),
      };
    case 'events':
      return {
        id: row.id,
        owner_id: row.ownerId,
        tour_id: row.tourId,
        name: row.name,
        venue_name_raw: row.venueNameRaw,
        event_date: fromDateOnly(row.eventDate as Date | null),
        starts_at: iso(row.startsAt as Date | null | undefined),
        created_at: iso(row.createdAt as Date),
        updated_at: iso(row.updatedAt as Date),
        deleted_at: iso(row.deletedAt as Date | null | undefined),
      };
    case 'applications':
      return {
        id: row.id,
        owner_id: row.ownerId,
        event_id: row.eventId,
        rep_identity_id: row.repIdentityId,
        rep_membership_id: row.repMembershipId,
        round_name: row.roundName,
        applied_on: fromDateOnly(row.appliedOn as Date | null),
        result_on: fromDateOnly(row.resultOn as Date | null),
        status: row.status,
        seat_raw: row.seatRaw,
        ticket_count: row.ticketCount,
        price_yen: row.priceYen,
        note: row.note,
        created_at: iso(row.createdAt as Date),
        updated_at: iso(row.updatedAt as Date),
        deleted_at: iso(row.deletedAt as Date | null | undefined),
      };
    case 'application_companions':
      return {
        id: row.id,
        owner_id: row.ownerId,
        application_id: row.applicationId,
        identity_id: row.identityId,
        display_name: row.displayName,
        position: row.position,
        created_at: iso(row.createdAt as Date),
        updated_at: iso(row.updatedAt as Date),
        deleted_at: iso(row.deletedAt as Date | null | undefined),
      };
    default:
      return row;
  }
}
