import { Injectable, Logger } from '@nestjs/common';
import { MailSender } from '../../mail/mail.sender';
import { AuthService } from '../auth.service';
import { normalizeEmail } from '../dto/password-rules';
import { RequestPasswordResetDto } from '../dto/reset-request.dto';
import { buildPasswordResetMail } from '../reset-mail';

/**
 * パスワード再設定コードの発行（FR-PR-2）。
 * 登録の有無・パスワード設定の有無に関わらず**常に 202 / 空ボディ**を返す
 * （アカウント列挙を防ぐ・AC-PR-01）。メール送信失敗も応答を変えない（AC-PR-06）。
 */
@Injectable()
export class RequestPasswordResetUseCase {
  private readonly logger = new Logger(RequestPasswordResetUseCase.name);

  constructor(
    private readonly auth: AuthService,
    private readonly mail: MailSender,
  ) {}

  async execute(dto: RequestPasswordResetDto): Promise<void> {
    const emailNormalized = normalizeEmail(dto.email);
    const user = await this.auth.findByEmailNormalized(emailNormalized);

    // Apple / Google のみのアカウントにはコードを送らない（AC-PR-02）
    if (!user || !user.passwordHash) return;

    const code = await this.auth.issueResetCode(user.id);
    const mail = buildPasswordResetMail(code);

    try {
      await this.mail.send({
        to: user.email ?? emailNormalized,
        subject: mail.subject,
        text: mail.text,
      });
    } catch (error) {
      // 応答で存在を漏らさないため 202 を維持する。コード本文はログに出さない
      this.logger.error(
        `failed to send password reset mail user_id=${user.id}`,
        error instanceof Error ? error.stack : String(error),
      );
    }
  }
}
