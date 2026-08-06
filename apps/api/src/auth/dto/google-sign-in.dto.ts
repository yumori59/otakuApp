import { IsNotEmpty, IsOptional, IsString, MaxLength } from 'class-validator';

/** `POST /v1/auth/google` のリクエスト（api-contract-delta.md §1）。 */
export class GoogleSignInDto {
  /** Google SDK の命名に合わせる（Apple は identity_token）。 */
  @IsString()
  @IsNotEmpty()
  @MaxLength(8192)
  id_token!: string;

  /** 送られた場合のみ id_token の nonce と突き合わせる。 */
  @IsOptional()
  @IsString()
  @IsNotEmpty()
  @MaxLength(512)
  nonce?: string;
}
