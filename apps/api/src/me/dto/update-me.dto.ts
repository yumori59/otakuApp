import { IsISO8601, IsOptional, IsString, Length, Matches } from 'class-validator';

const THEME_COLOR_RE = /^#[0-9A-Fa-f]{6}$/;

/**
 * `PATCH /v1/me` の受け入れ可能キー (api-contract.md §2)。
 * 送られたキーのみが更新対象。読み取り専用キー (id / account_id / plan 等) は
 * わざと定義しない — ValidationPipe の forbidNonWhitelisted で 400 になる (AC-ME-04)。
 */
export class UpdateMeDto {
  @IsOptional()
  @IsString()
  display_name?: string;

  @IsOptional()
  @IsString()
  @Length(1, 30)
  username?: string;

  @IsOptional()
  @IsString()
  @Length(1, 30)
  app_display_name?: string;

  @IsOptional()
  @Matches(THEME_COLOR_RE)
  theme_color?: string;

  @IsOptional()
  @IsString()
  locale?: string;

  @IsOptional()
  @IsString()
  timezone?: string;

  @IsOptional()
  @IsISO8601()
  onboarded_at?: string;
}
