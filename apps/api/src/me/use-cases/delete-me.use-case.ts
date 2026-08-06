import { Injectable, Logger } from '@nestjs/common';
import { AppleTokenRevoker } from '../../auth/apple-token.revoker';
import { PasswordHasher } from '../../auth/password.hasher';
import { CREDENTIALS_INVALID_MESSAGE } from '../../auth/use-cases/login-with-email.use-case';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { DeleteMeDto } from '../dto/delete-me.dto';
import { MeService } from '../me.service';

/**
 * `DELETE /v1/me`（account-deletion/api-contract-delta.md §1・FR-AD-1〜4）。
 *
 * 対象は常に引数の `userId`（Bearer の `sub`）。ボディで対象を指定させない（BE-4）。
 * Prisma には触れない。DB 操作は `MeService` 経由のみ（BE-3 / ADR-009）。
 * `password` / `apple_authorization_code` の値は例外・ログに載せない（NFR-AD-3 / AC-AD-13）。
 */
@Injectable()
export class DeleteMeUseCase {
  private readonly logger = new Logger(DeleteMeUseCase.name);

  constructor(
    private readonly meService: MeService,
    private readonly hasher: PasswordHasher,
    private readonly appleTokenRevoker: AppleTokenRevoker,
  ) {}

  async execute(userId: string, dto: DeleteMeDto = {}): Promise<void> {
    const user = await this.meService.findUserForDeletion(userId);
    if (!user) throw AppError.notFound('user not found');

    // password_hash が null（Apple / Google のみ）のときは password を要求しない。
    // 送られてきても無視する（誤って締め出さない — E-11）。
    if (user.passwordHash) {
      if (!dto.password) {
        throw AppError.validation('password is required for this account');
      }
      const matched = await this.hasher.verify(dto.password, user.passwordHash);
      if (!matched) {
        throw new AppError(
          ErrorCode.AUTH_CREDENTIALS_INVALID,
          CREDENTIALS_INVALID_MESSAGE,
        );
      }
    }

    await this.meService.deleteAccount(userId);

    // ここから先は削除済み。Apple のトークン失効はベストエフォート（FR-AD-11 / D3 / E-7）。
    // 失敗しても 204 を変えない。例外の中身はコードを含み得るのでログに載せない（NFR-AD-3）。
    if (dto.apple_authorization_code) {
      try {
        await this.appleTokenRevoker.revokeAuthorizationCode(
          dto.apple_authorization_code,
        );
      } catch {
        this.logger.warn(
          `Apple のトークン失効に失敗しましたがアカウント削除は完了しています user_id=${userId}`,
        );
      }
    }
  }
}
