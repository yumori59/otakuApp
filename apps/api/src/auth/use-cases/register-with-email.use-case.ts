import { Injectable } from '@nestjs/common';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AuthService } from '../auth.service';
import { SignInResponse } from '../auth.types';
import { normalizeEmail } from '../dto/password-rules';
import { RegisterDto } from '../dto/register.dto';
import { PasswordHasher } from '../password.hasher';
import { toSignInResponse } from '../sign-in-response';

/**
 * メール + パスワードの新規登録（FR-EP-1）。
 * 201 / `is_new: true`。ボディ形状は `POST /v1/auth/apple` と同形。
 */
@Injectable()
export class RegisterWithEmailUseCase {
  constructor(
    private readonly auth: AuthService,
    private readonly hasher: PasswordHasher,
  ) {}

  async execute(dto: RegisterDto): Promise<SignInResponse> {
    const emailNormalized = normalizeEmail(dto.email);

    // 事前チェック（競合時は createEmailUser 側の P2002 が同じ 409 に写す・BE-6）
    const existing = await this.auth.findByEmailNormalized(emailNormalized);
    if (existing) {
      throw new AppError(
        ErrorCode.EMAIL_ALREADY_REGISTERED,
        'email is already registered',
      );
    }

    const passwordHash = await this.hasher.hash(dto.password);
    const user = await this.auth.createEmailUser({
      email: dto.email,
      emailNormalized,
      passwordHash,
    });

    const access = await this.auth.issueAccessToken(user.userId);
    const refresh = await this.auth.issueRefreshToken(user.userId);

    return toSignInResponse(user, access, refresh);
  }
}
