import { Transform } from 'class-transformer';
import { IsArray, IsBoolean, IsIn, IsOptional, IsUUID } from 'class-validator';
import { PaginationQueryDto } from '../../common/dto/pagination.dto';
import { APPLICATION_STATUSES, ApplicationStatus } from './application-status';

/**
 * GET /v1/applications のクエリ (api-contract.md §7)。
 * `limit` / `cursor` は共通の PaginationQueryDto を継承する。
 * `status` は複数指定可 (`?status=applied&status=won`)。未知値は 400（BE-2）。
 */
export class ListApplicationsQueryDto extends PaginationQueryDto {
  @IsOptional()
  @Transform(({ value }: { value: unknown }) =>
    value === undefined ? undefined : Array.isArray(value) ? value : [value],
  )
  @IsArray()
  @IsIn(APPLICATION_STATUSES, { each: true })
  status?: ApplicationStatus[];

  @IsOptional()
  @IsUUID()
  tour_id?: string;

  @IsOptional()
  @IsUUID()
  event_id?: string;

  @IsOptional()
  @IsUUID()
  rep_identity_id?: string;

  @IsOptional()
  @Transform(({ value }: { value: unknown }) => {
    if (value === 'true') return true;
    if (value === 'false') return false;
    return value;
  })
  @IsBoolean()
  include_deleted?: boolean;
}
