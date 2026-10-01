import { toDateOnly } from '../common/util/date.util';
import {
  IDENTITY_ROLES,
  MAX_REPRESENTATIVE_NAME_LENGTH,
  normalizeRepresentativeName,
} from '../applications/dto/identity-role';
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
        memberNo: payload.member_no ?? null,
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
        ...applicationRoleData(payload),
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

/**
 * applications payload の立場フィールド。role 省略 = フィールドを返さない（create は既定の representative、update は既存値を保持）。
 * representative のとき representative_name は常に null。
 * 未知 role / 不正な name は `validateApplicationRolePayload` が事前に reject する
 * ため、ここでは黙ってフォールバックしない（未知値は検証済みの前提で素通し）。
 */
function applicationRoleData(payload: Record<string, unknown>): {
  identityRole?: unknown;
  representativeName?: string | null;
} {
  // キー自体が無い旧クライアントの push は、既存行の立場を上書きしない
  // （update に値を入れない）。create は Prisma の @default("representative") に任せる。
  if (payload.identity_role === undefined || payload.identity_role === null) {
    return {};
  }
  const identityRole = payload.identity_role;
  const name =
    typeof payload.representative_name === 'string'
      ? payload.representative_name
      : null;
  return {
    identityRole,
    representativeName:
      identityRole === 'representative'
        ? null
        : normalizeRepresentativeName(name),
  };
}

/**
 * applications payload の identity_role / representative_name を検証する。
 * 不正なら reject 理由、問題なければ null（sync push の SYNC_APPLY_FAILED 用）。
 */
export function validateApplicationRolePayload(
  payload: Record<string, unknown>,
): string | null {
  const role = payload.identity_role;
  if (
    role !== undefined &&
    role !== null &&
    !(IDENTITY_ROLES as readonly unknown[]).includes(role)
  ) {
    return `identity_role must be one of: ${IDENTITY_ROLES.join(', ')}`;
  }
  const name = payload.representative_name;
  if (name !== undefined && name !== null) {
    if (typeof name !== 'string') {
      return 'representative_name must be a string';
    }
    if (name.trim().length > MAX_REPRESENTATIVE_NAME_LENGTH) {
      return `representative_name must be at most ${MAX_REPRESENTATIVE_NAME_LENGTH} characters`;
    }
  }
  return null;
}

export function isDeletedPayload(payload: Record<string, unknown>): boolean {
  const deletedAt = payload.deleted_at;
  return deletedAt !== null && deletedAt !== undefined;
}
