import { IsOptional, IsUUID } from 'class-validator';

/** GET /v1/memberships のクエリ (api-contract.md §4)。未指定なら自分の全件。 */
export class ListMembershipsQueryDto {
  @IsOptional()
  @IsUUID()
  identity_id?: string;
}
