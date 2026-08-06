import {
  IsBoolean,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  Max,
  MaxLength,
  Min,
  MinLength,
} from 'class-validator';

const MEMBER_NO_LAST4_RE = /^[0-9A-Za-z]{1,4}$/;
const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * PATCH /v1/memberships/:id のリクエストボディ (api-contract.md §4)。
 * POST と同じフィールド（`id` を除く）、すべて任意。
 * `identity_id` の変更時も所有検証する (FR-MB-2)。
 * `member_no` / `member_no_cipher` / `owner_id` は定義しない (FR-MB-3, FR-MB-4)。
 */
export class UpdateMembershipDto {
  @IsOptional()
  @IsUUID()
  identity_id?: string;

  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(200)
  fan_club_name_raw?: string;

  @IsOptional()
  @Matches(MEMBER_NO_LAST4_RE, {
    message: 'member_no_last4 must be 1-4 alphanumeric characters',
  })
  member_no_last4?: string;

  @IsOptional()
  @IsString()
  @MaxLength(50)
  rank?: string;

  @IsOptional()
  @Matches(DATE_ONLY_RE, { message: 'renewal_on must be YYYY-MM-DD' })
  renewal_on?: string | null;

  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(1000000)
  fee_yen?: number;

  @IsOptional()
  @IsBoolean()
  auto_renew?: boolean;

  @IsOptional()
  @IsString()
  @MaxLength(2000)
  note?: string | null;
}
