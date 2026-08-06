import { Injectable } from '@nestjs/common';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AuthService } from '../auth.service';
import { TokenPairResponse } from '../auth.types';
import { ChangePasswordDto } from '../dto/change-password.dto';
import { PasswordHasher } from '../password.hasher';
import { toTokenPairResponse } from '../sign-in-response';
import { CREDENTIALS_INVALID_MESSAGE } from './login-with-email.use-case';

/**
 * ログイン中ユーザーのパスワード変更（FR-EP-7）。
 * 成功時は既存 refresh をすべて失効させ、新しいペアを返す（AC-EP-11）。
 */
@Injectable()
export class ChangePasswordUseCase {
  constructor(
    private readonly auth: AuthService,
    private readonly hasher: PasswordHasher,
  ) {}

  async execute(
    userId: string,
    dto: ChangePasswordDto,
  ): Promise<TokenPairResponse> {
    if (dto.current_password === dto.new_password) {
      throw AppError.validation(
        'new_password must be different from current_password',
      );
    }

    const row = await this.auth.findUserById(userId);
    if (!row) throw AppError.unauthenticated();

    // Apple / Google のみのアカウントには変更するパスワードが無い
    if (!row.passwordHash) {
      throw new AppError(
        ErrorCode.FORBIDDEN,
        'password is not set for this account',
      );
    }

    const matched = await this.hasher.verify(
      dto.current_password,
      row.passwordHash,
    );
    if (!matched) {
      throw new AppError(
        ErrorCode.AUTH_CREDENTIALS_INVALID,
        CREDENTIALS_INVALID_MESSAGE,
      );
    }

    const passwordHash = await this.hasher.hash(dto.new_password);
    const refresh = await this.auth.changePassword(userId, passwordHash);
    const access = await this.auth.issueAccessToken(userId);

    return toTokenPairResponse(access, refresh);
  }
}
