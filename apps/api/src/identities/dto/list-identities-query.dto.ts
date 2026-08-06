import { Transform } from 'class-transformer';
import { IsBoolean, IsOptional } from 'class-validator';

/** GET /v1/identities のクエリ (api-contract.md §3)。既定 include_deleted=false。 */
export class ListIdentitiesQueryDto {
  @IsOptional()
  @Transform(({ value }: { value: unknown }) => {
    if (value === 'true') return true;
    if (value === 'false') return false;
    return value;
  })
  @IsBoolean()
  include_deleted?: boolean;
}
