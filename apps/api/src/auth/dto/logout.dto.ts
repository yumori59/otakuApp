import { IsNotEmpty, IsString, MaxLength } from 'class-validator';

/** `POST /v1/auth/logout` のリクエスト（api-contract.md §1）。 */
export class LogoutDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(512)
  refresh_token!: string;
}
