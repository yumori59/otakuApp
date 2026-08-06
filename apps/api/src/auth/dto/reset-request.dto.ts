import { IsEmail, MaxLength } from 'class-validator';
import { EMAIL_MAX_LENGTH, TrimEmail } from './password-rules';

/** `POST /v1/auth/password/reset-request` のリクエスト（api-contract-delta.md §1）。 */
export class RequestPasswordResetDto {
  @TrimEmail()
  @IsEmail()
  @MaxLength(EMAIL_MAX_LENGTH)
  email!: string;
}
