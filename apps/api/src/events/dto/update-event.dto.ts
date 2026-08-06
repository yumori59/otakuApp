import {
  IsISO8601,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  MinLength,
} from 'class-validator';

const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;

/**
 * PATCH /v1/events/:id (api-contract.md §6)。
 * 変更できるのは name / venue_name_raw / event_date / starts_at のみ。
 * `tour_id` の付け替えは不可 — 送られたら forbidNonWhitelisted で 400。
 */
export class UpdateEventDto {
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(200)
  name?: string;

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
