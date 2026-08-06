import { IsEmail, IsString, Length, Matches, MaxLength } from 'class-validator';
import { RESET_CODE_PATTERN } from '../reset-code.generator';
import {
  EMAIL_MAX_LENGTH,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
  TrimEmail,
} from './password-rules';

/** `POST /v1/auth/password/reset` のリクエスト（api-contract-delta.md §1）。 */
export class ResetPasswordDto {
  @TrimEmail()
  @IsEmail()
  @MaxLength(EMAIL_MAX_LENGTH)
  email!: string;

  /** 8 桁の数字（先頭 0 を許す）。 */
  @IsString()
  @Matches(RESET_CODE_PATTERN)
  code!: string;

  @IsString()
  @Length(PASSWORD_MIN_LENGTH, PASSWORD_MAX_LENGTH)
  new_password!: string;
}
