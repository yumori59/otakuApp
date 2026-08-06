import { IsArray, IsIn, IsISO8601, IsOptional, IsString, IsUUID, ValidateNested } from 'class-validator';
import { Type } from 'class-transformer';
import { SYNC_COLLECTIONS } from '../sync-collections';

export class SyncPullDto {
  @IsOptional()
  @IsISO8601()
  cursor?: string;

  @IsArray()
  @IsString({ each: true })
  @IsIn([...SYNC_COLLECTIONS], { each: true })
  collections!: string[];
}

export class SyncMutationDto {
  @IsIn([...SYNC_COLLECTIONS])
  collection!: string;

  @IsIn(['upsert'])
  op!: 'upsert';

  @IsUUID()
  id!: string;

  @IsISO8601()
  updated_at!: string;

  /** snake_case フィールド。コレクションごとに whitelist は Service 側。 */
  payload!: Record<string, unknown>;
}

export class SyncPushDto {
  @IsArray()
  @ValidateNested({ each: true })
  @Type(() => SyncMutationDto)
  mutations!: SyncMutationDto[];
}
