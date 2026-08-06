import { Application } from '@prisma/client';
import { fromDateOnly } from '../common/util/date.util';

/** api-contract.md §7 の companions 要素。 */
export interface ApplicationCompanionResponse {
  id: string;
  identity_id: string | null;
  display_name: string;
  position: number;
}

/** api-contract.md §7 の application レスポンス要素（snake_case）。 */
export interface ApplicationResponse {
  id: string;
  tour_id: string;
  event_id: string;
  rep_identity_id: string;
  rep_membership_id: string | null;
  round_name: string | null;
  applied_on: string | null;
  result_on: string | null;
  status: string;
  seat_raw: string | null;
  ticket_count: number;
  price_yen: number | null;
  note: string | null;
  companions: ApplicationCompanionResponse[];
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

export interface CompanionRowLike {
  id: string;
  identityId: string | null;
  displayName: string;
  position: number;
}

/** `tour_id` は applications に列が無いため event から導出する。 */
export type ApplicationRowLike = Application & {
  event: { tourId: string };
  companions: CompanionRowLike[];
};

export function toApplicationResponse(
  row: ApplicationRowLike,
): ApplicationResponse {
  return {
    id: row.id,
    tour_id: row.event.tourId,
    event_id: row.eventId,
    rep_identity_id: row.repIdentityId,
    rep_membership_id: row.repMembershipId,
    round_name: row.roundName,
    applied_on: fromDateOnly(row.appliedOn),
    result_on: fromDateOnly(row.resultOn),
    status: row.status,
    seat_raw: row.seatRaw,
    ticket_count: row.ticketCount,
    price_yen: row.priceYen,
    note: row.note,
    companions: row.companions.map((companion) => ({
      id: companion.id,
      identity_id: companion.identityId,
      display_name: companion.displayName,
      position: companion.position,
    })),
    created_at: row.createdAt.toISOString(),
    updated_at: row.updatedAt.toISOString(),
    deleted_at: row.deletedAt ? row.deletedAt.toISOString() : null,
  };
}
