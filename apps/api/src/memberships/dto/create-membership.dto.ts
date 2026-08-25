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

// 制御文字 (Cc) ・書式文字 (Cf) のみ禁止。文字種は絞らない (D-2)。
const MEMBER_NO_RE = /^[^\p{Cc}\p{Cf}]+$/u;
const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * POST /v1/memberships のリクエストボディ (api-contract.md §4)。
 * `id` はクライアント発行 UUID（サーバーはバージョンを検証しない — BE-1）。
 * `member_no_last4` / `member_no_cipher` はわざと定義しない
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
  @IsString()
  @MinLength(1)
  @MaxLength(64)
  @Matches(MEMBER_NO_RE, {
    message: 'member_no must not contain control characters',
  })
  member_no?: string;

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
