import { IsEmail, IsString, Length, MaxLength } from 'class-validator';
import {
  EMAIL_MAX_LENGTH,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  TrimEmail,
} from './password-rules';

/** `POST /v1/auth/register` のリクエスト（api-contract-delta.md §1）。 */
export class RegisterDto {
  @TrimEmail()
  @IsEmail()
  @MaxLength(EMAIL_MAX_LENGTH)
  email!: string;

  @IsString()
  @Length(PASSWORD_MIN_LENGTH, PASSWORD_MAX_LENGTH)
  password!: string;
}
