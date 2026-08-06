import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsDefined,
  IsIn,
  IsInt,
  IsISO8601,
  IsObject,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  Max,
  MaxLength,
  Min,
  MinLength,
  Validate,
  ValidateNested,
  ValidatorConstraint,
  ValidatorConstraintInterface,
} from 'class-validator';
import { APPLICATION_STATUSES } from './application-status';
import type { ApplicationStatus } from './application-status';

const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;

export const MAX_COMPANIONS = 3;

/** companions の identity_id 重複を弾く（E-7）。null は重複扱いしない。 */
@ValidatorConstraint({ name: 'uniqueCompanionIdentityIds', async: false })
export class UniqueCompanionIdentityIds implements ValidatorConstraintInterface {
  validate(value: unknown): boolean {
    if (!Array.isArray(value)) return true;
    const ids = value
      .map((item) => (item as { identity_id?: string | null })?.identity_id)
      .filter((id): id is string => typeof id === 'string');
    return new Set(ids).size === ids.length;
  }

  defaultMessage(): string {
    return 'companions must not contain duplicated identity_id';
  }
}

/** POST / PATCH /v1/applications の companions 要素。 */
export class ApplicationCompanionDto {
  @IsOptional()
  @IsUUID()
  id?: string;

  @IsOptional()
  @IsUUID()
  identity_id?: string | null;

  @IsString()
  @MinLength(1)
  @MaxLength(60)
  display_name!: string;

  @IsOptional()
  @IsInt()
  @Min(0)
  position?: number;
}

/** find-or-create される tour ブロック（api-contract.md §7）。 */
export class CreateApplicationTourDto {
  @IsOptional()
  @IsUUID()
  id?: string;

  @IsString()
  @MinLength(1)
  @MaxLength(200)
  name!: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  artist_name_raw?: string | null;
}

/** upsert される event ブロック（api-contract.md §7）。 */
export class CreateApplicationEventDto {
  @IsOptional()
  @IsUUID()
  id?: string;

  @IsString()
  @MinLength(1)
  @MaxLength(200)
  name!: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  venue_name_raw?: string | null;

  @IsOptional()
  @Matches(DATE_ONLY_RE, { message: 'event_date must be YYYY-MM-DD' })
  event_date?: string | null;

  @IsOptional()
  @IsISO8601()
  starts_at?: string | null;
}

/**
 * POST /v1/applications のリクエストボディ (api-contract.md §7)。
 * id / tour.id / event.id / companions[].id はクライアント発行 UUID
 * （サーバーはバージョンを検証しない — BE-1。省略時はサーバーが発行する）。
 */
export class CreateApplicationDto {
  @IsOptional()
  @IsUUID()
  id?: string;

  @IsDefined()
  @IsObject()
  @ValidateNested()
  @Type(() => CreateApplicationTourDto)
  tour!: CreateApplicationTourDto;

  @IsDefined()
  @IsObject()
  @ValidateNested()
  @Type(() => CreateApplicationEventDto)
  event!: CreateApplicationEventDto;

  @IsUUID()
  rep_identity_id!: string;

  @IsOptional()
  @IsUUID()
  rep_membership_id?: string | null;

  @IsOptional()
  @IsString()
  @MaxLength(100)
  round_name?: string | null;

  @IsOptional()
  @Matches(DATE_ONLY_RE, { message: 'applied_on must be YYYY-MM-DD' })
  applied_on?: string | null;

  @IsOptional()
  @Matches(DATE_ONLY_RE, { message: 'result_on must be YYYY-MM-DD' })
  result_on?: string | null;

  @IsOptional()
  @IsIn(APPLICATION_STATUSES)
  status?: ApplicationStatus;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  seat_raw?: string | null;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(20)
  ticket_count?: number;

  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(10_000_000)
  price_yen?: number | null;

  @IsOptional()
  @IsString()
  @MaxLength(2000)
  note?: string | null;

  @IsOptional()
  @IsArray()
  @ArrayMaxSize(MAX_COMPANIONS)
  @Validate(UniqueCompanionIdentityIds)
  @ValidateNested({ each: true })
  @Type(() => ApplicationCompanionDto)
  companions?: ApplicationCompanionDto[];
}
