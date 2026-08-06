import { IsNotEmpty, IsString, MaxLength } from 'class-validator';

/** `POST /v1/auth/refresh` のリクエスト（api-contract.md §1）。 */
export class RefreshDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(512)
  refresh_token!: string;
}
