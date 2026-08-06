import { IsString, Length, MaxLength } from 'class-validator';
import {
  LOGIN_PASSWORD_MAX_LENGTH,
  PASSWORD_MAX_LENGTH,
  PASSWORD_MIN_LENGTH,
} from './password-rules';

/** `POST /v1/auth/password` のリクエスト（api-contract-delta.md §1・認証必須）。 */
export class ChangePasswordDto {
  /** 現行パスワードは旧ポリシーの可能性があるので下限を掛けない。 */
  @IsString()
  @MaxLength(LOGIN_PASSWORD_MAX_LENGTH)
  current_password!: string;

  @IsString()
  @Length(PASSWORD_MIN_LENGTH, PASSWORD_MAX_LENGTH)
  new_password!: string;
}
