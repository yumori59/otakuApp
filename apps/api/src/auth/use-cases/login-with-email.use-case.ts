import { Injectable } from '@nestjs/common';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AuthService } from '../auth.service';
import { SignInResponse } from '../auth.types';
import { LoginDto } from '../dto/login.dto';
import { normalizeEmail } from '../dto/password-rules';
import { PasswordHasher } from '../password.hasher';
import { toSignInResponse } from '../sign-in-response';

/** 失敗理由を区別しないための固定メッセージ（api-contract-delta.md §1）。 */
export const CREDENTIALS_INVALID_MESSAGE = 'invalid email or password';

/**
 * メール + パスワードのログイン（FR-EP-4）。
 * 未登録 / パスワード誤り / パスワード未設定を **区別せず** 同一の 401 にする（AC-EP-08）。
 */
@Injectable()
export class LoginWithEmailUseCase {
  constructor(
    private readonly auth: AuthService,
    private readonly hasher: PasswordHasher,
  ) {}

  async execute(dto: LoginDto): Promise<SignInResponse> {
    const emailNormalized = normalizeEmail(dto.email);
    const row = await this.auth.findByEmailNormalized(emailNormalized);

    // ユーザーが居なくてもハッシュ計算を必ず 1 回通す（存在をタイミングで漏らさない・AC-EP-09）
    const matched = await this.hasher.verify(
      dto.password,
      row?.passwordHash ?? null,
    );
    if (!row || !row.passwordHash || !matched) throw credentialsInvalid();

    // 既定パラメータが変わっていたらこの機会に作り直す（AC-EP-10）
    if (this.hasher.needsRehash(row.passwordHash)) {
      await this.auth.updatePasswordHash(
        row.id,
        await this.hasher.hash(dto.password),
      );
    }

    const user = await this.auth.loadUser(row.id);
    if (!user) throw credentialsInvalid();

    const access = await this.auth.issueAccessToken(user.userId);
    const refresh = await this.auth.issueRefreshToken(user.userId);

    return toSignInResponse(user, access, refresh);
  }
}

function credentialsInvalid(): AppError {
  return new AppError(
    ErrorCode.AUTH_CREDENTIALS_INVALID,
    CREDENTIALS_INVALID_MESSAGE,
  );
}
