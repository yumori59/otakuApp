import { Injectable } from '@nestjs/common';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AuthService } from '../auth.service';
import { SignInResponse } from '../auth.types';
import { normalizeEmail } from '../dto/password-rules';
import { ResetPasswordDto } from '../dto/reset-password.dto';
import { PasswordHasher } from '../password.hasher';
import { toSignInResponse } from '../sign-in-response';

/** 失敗理由を区別しないための固定メッセージ（api-contract-delta.md §1）。 */
export const RESET_CODE_INVALID_MESSAGE = 'invalid or expired reset code';

/**
 * リセットコードによるパスワード再設定（FR-PR-6）。
 * 未知 email / 誤コード / 期限切れ / 使用済み / 試行超過は**すべて同一の 401**（AC-PR-09）。
 */
@Injectable()
export class ResetPasswordUseCase {
  constructor(
    private readonly auth: AuthService,
    private readonly hasher: PasswordHasher,
  ) {}

  async execute(dto: ResetPasswordDto): Promise<SignInResponse> {
    const emailNormalized = normalizeEmail(dto.email);
    const row = await this.auth.findByEmailNormalized(emailNormalized);
    if (!row || !row.passwordHash) throw resetCodeInvalid();

    const code = await this.auth.findActiveResetCode(row.id, dto.code);
    if (!code) {
      // 誤りを 1 回数える（上限に達したら Service 側でそのコードを失効させる・AC-PR-10）
      await this.auth.recordResetAttempt(row.id);
      throw resetCodeInvalid();
    }

    const passwordHash = await this.hasher.hash(dto.new_password);
    const refresh = await this.auth.consumeResetCode({
      userId: row.id,
      codeId: code.id,
      passwordHash,
    });

    const user = await this.auth.loadUser(row.id);
    if (!user) throw resetCodeInvalid();

    const access = await this.auth.issueAccessToken(row.id);

    return toSignInResponse(user, access, refresh);
  }
}

function resetCodeInvalid(): AppError {
  return new AppError(
    ErrorCode.AUTH_RESET_CODE_INVALID,
    RESET_CODE_INVALID_MESSAGE,
  );
}
