import { IsOptional, IsUUID } from 'class-validator';

/** GET /v1/events?tour_id= (api-contract.md §6)。 */
export class ListEventsQueryDto {
  @IsOptional()
  @IsUUID()
  tour_id?: string;
}
