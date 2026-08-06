import { IsEmail, IsString, MaxLength } from 'class-validator';
import {
  EMAIL_MAX_LENGTH,
  LOGIN_PASSWORD_MAX_LENGTH,
  TrimEmail,
} from './password-rules';

/**
 * `POST /v1/auth/login` のリクエスト（api-contract-delta.md §1）。
 * password に下限を掛けない（掛けると「8 文字未満 = 未登録」が 400 で判別できてしまう）。
 */
export class LoginDto {
  @TrimEmail()
  @IsEmail()
  @MaxLength(EMAIL_MAX_LENGTH)
  email!: string;

  @IsString()
  @MaxLength(LOGIN_PASSWORD_MAX_LENGTH)
  password!: string;
}
