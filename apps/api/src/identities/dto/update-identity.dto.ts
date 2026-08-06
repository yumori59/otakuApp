import {
  IsBoolean,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';
import { IDENTITY_RELATIONS } from './create-identity.dto';
import type { IdentityRelation } from './create-identity.dto';

const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;
const COLOR_HEX_RE = /^#[0-9A-Fa-f]{6}$/;

/**
 * PATCH /v1/identities/:id のリクエストボディ (api-contract.md §3)。
 * POST と同じフィールド（`id` を除く）、すべて任意。
 */
export class UpdateIdentityDto {
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(60)
  display_name?: string;

  @IsOptional()
  @IsIn(IDENTITY_RELATIONS)
  relation?: IdentityRelation;

  @IsOptional()
  @Matches(COLOR_HEX_RE, { message: 'color must be a 6-digit hex code' })
  color?: string;

  @IsOptional()
  @Matches(DATE_ONLY_RE, { message: 'joined_on must be YYYY-MM-DD' })
  joined_on?: string | null;

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
