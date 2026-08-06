import { Type } from 'class-transformer';
import { IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';

export const DEFAULT_PAGE_LIMIT = 50;
export const MAX_PAGE_LIMIT = 200;
export const MAX_CURSOR_LENGTH = 200;

/**
 * カーソルページングの共通クエリ (api-contract.md §0)。
 * cursor は前ページの `next_cursor` をそのまま渡す opaque トークン。
 * 中身（`<updated_at>|<id>`）はサーバー実装の詳細で、クライアントは解釈しない。
 * 形式の検証はページング条件を組み立てる service 側で行う（不正は 400）。
 */
export class PaginationQueryDto {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(MAX_PAGE_LIMIT)
  limit: number = DEFAULT_PAGE_LIMIT;

  @IsOptional()
  @IsString()
  @MaxLength(MAX_CURSOR_LENGTH)
  cursor?: string;
}
