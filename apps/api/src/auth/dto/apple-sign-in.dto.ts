import { IsNotEmpty, IsOptional, IsString, MaxLength } from 'class-validator';

/** `POST /v1/auth/apple` のリクエスト（api-contract.md §1）。 */
export class AppleSignInDto {
  @IsString()
  @IsNotEmpty()
  @MaxLength(8192)
  identity_token!: string;

  /** 送られた場合のみ identity token の nonce と突き合わせる。 */
  @IsOptional()
  @IsString()
  @IsNotEmpty()
  @MaxLength(512)
  nonce?: string;
}
