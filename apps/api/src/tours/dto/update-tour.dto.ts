import { IsOptional, IsString, MaxLength, MinLength } from 'class-validator';

/**
 * PATCH /v1/tours/:id (api-contract.md §5)。
 * 変更できるのは name / artist_name_raw のみ。
 * それ以外のキーは ValidationPipe の forbidNonWhitelisted で 400。
 */
export class UpdateTourDto {
  @IsOptional()
  @IsString()
  @MinLength(1)
  @MaxLength(200)
  name?: string;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  artist_name_raw?: string | null;
}
