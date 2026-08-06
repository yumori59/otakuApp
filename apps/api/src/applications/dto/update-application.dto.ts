import { Type } from 'class-transformer';
import {
  ArrayMaxSize,
  IsArray,
  IsIn,
  IsInt,
  IsOptional,
  IsString,
  IsUUID,
  Matches,
  Max,
  MaxLength,
  Min,
  Validate,
  ValidateNested,
} from 'class-validator';
import { APPLICATION_STATUSES } from './application-status';
import type { ApplicationStatus } from './application-status';
import {
  ApplicationCompanionDto,
  MAX_COMPANIONS,
  UniqueCompanionIdentityIds,
} from './create-application.dto';

const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * PATCH /v1/applications/:id (api-contract.md §7)。
 * `event_id` / `tour_id`（および tour / event ブロック）の付け替えは不可 —
 * 送られたら ValidationPipe の forbidNonWhitelisted で 400 (AC-APP-14)。
 * `companions` を渡した場合は全置換、キー自体が無ければ変更しない (FR-AP-8)。
 */
export class UpdateApplicationDto {
  @IsOptional()
  @IsUUID()
  rep_identity_id?: string;

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
