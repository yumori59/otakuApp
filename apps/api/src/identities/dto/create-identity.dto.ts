import {
  IsBoolean,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';

/** api-contract.md §0 enum 値。黙って別値へフォールバックしない（BE-2）。 */
export const IDENTITY_RELATIONS = ['self', 'family', 'friend', 'other'] as const;
export type IdentityRelation = (typeof IDENTITY_RELATIONS)[number];

const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;
const COLOR_HEX_RE = /^#[0-9A-Fa-f]{6}$/;

/**
 * POST /v1/identities のリクエストボディ (api-contract.md §3)。
 * `id` はクライアント発行 UUID（サーバーはバージョンを検証しない — BE-1）。
 */
export class CreateIdentityDto {
  @IsUUID()
  id!: string;

  @IsString()
  @MinLength(1)
  @MaxLength(60)
  display_name!: string;

  @IsOptional()
  @IsIn(IDENTITY_RELATIONS)
  relation?: IdentityRelation;

  @IsOptional()
  @Matches(COLOR_HEX_RE, { message: 'color must be a 6-digit hex code' })
  color?: string;

  @IsOptional()
  @Matches(DATE_ONLY_RE, { message: 'joined_on must be YYYY-MM-DD' })
  joined_on?: string;

  @IsOptional()
  @IsString()
  @MaxLength(2000)
  note?: string | null;

  @IsOptional()
  @IsBoolean()
  history_visible?: boolean;

  @IsOptional()
  @IsInt()
  sort_order?: number;
}
