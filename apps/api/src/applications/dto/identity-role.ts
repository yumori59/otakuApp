/**
 * 申込の立場（`applications.identity_role`）。
 * representative = 名義本人の申込 / companion = 他の人（representative_name）の申込に同行。
 * この値以外は 400 / sync reject。黙って representative に落とさない（BE-2）。
 */
export const IDENTITY_ROLES = ['representative', 'companion'] as const;

export type IdentityRole = (typeof IDENTITY_ROLES)[number];

/** role 省略時の既定値。 */
export const DEFAULT_IDENTITY_ROLE: IdentityRole = 'representative';

export const MAX_REPRESENTATIVE_NAME_LENGTH = 100;

/** trim し、空文字は null。 */
export function normalizeRepresentativeName(
  value: string | null | undefined,
): string | null {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim();
  return trimmed === '' ? null : trimmed;
}

export interface ResolvedRoleFields {
  identityRole: IdentityRole;
  representativeName: string | null;
}

/** 作成時: role 省略 = representative。representative のとき name は常に null。 */
export function resolveRoleOnCreate(
  role: IdentityRole | undefined,
  name: string | null | undefined,
): ResolvedRoleFields {
  const identityRole = role ?? DEFAULT_IDENTITY_ROLE;
  return {
    identityRole,
    representativeName:
      identityRole === 'representative'
        ? null
        : normalizeRepresentativeName(name),
  };
}

/**
 * 更新時: 渡されたキーだけ返す（Prisma の update data 形）。
 * 更新後の role が representative になる場合、name は必ず null（不変条件）。
 * `currentRole` は DB 上の現在値（name だけが送られた場合の判定に使う）。
 */
export function resolveRoleOnUpdate(
  dto: {
    identity_role?: IdentityRole;
    representative_name?: string | null;
  },
  currentRole: string,
): Partial<ResolvedRoleFields> {
  const result: Partial<ResolvedRoleFields> = {};
  if (dto.identity_role !== undefined) {
    result.identityRole = dto.identity_role;
  }
  const effectiveRole = dto.identity_role ?? currentRole;
  if (effectiveRole === 'representative') {
    if (dto.identity_role !== undefined || dto.representative_name !== undefined) {
      result.representativeName = null;
    }
  } else if (dto.representative_name !== undefined) {
    result.representativeName = normalizeRepresentativeName(
      dto.representative_name,
    );
  }
  return result;
}
