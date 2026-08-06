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
 * POST /v1/memberships のリクエストボディ (api-contract.md §4)。
 * `id` はクライアント発行 UUID（サーバーはバージョンを検証しない — BE-1）。
 * `member_no` / `member_no_cipher` はわざと定義しない
 * — ValidationPipe の forbidNonWhitelisted で 400 になる (FR-MB-4)。
 * `owner_id` も定義しない（親 identity から継承 — FR-MB-3）。
 */
export class CreateMembershipDto {
  @IsUUID()
  id!: string;

  @IsUUID()
  identity_id!: string;

  @IsString()
  @MinLength(1)
  @MaxLength(200)
  fan_club_name_raw!: string;

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
  renewal_on?: string;

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
