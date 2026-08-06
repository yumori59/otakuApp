import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Resend } from 'resend';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { MailSendInput, MailSender } from './mail.sender';

/**
 * Resend（https://resend.com）経由のメール送信。
 * 本番で RESEND_API_KEY 未設定なら送信時に INTERNAL 500（AC-T0-06）。
 * 非本番かつ未設定のときだけ、ローカル開発用に本文をログへフォールバック出力する。
 * それ以外の送信失敗（Resend API エラー）はそのまま例外として投げる
 * （202 を返す・失敗を握りつぶすのは呼び出し元 = T1 のユースケースの責務）。
 */
@Injectable()
export class ResendMailSender extends MailSender {
  private readonly logger = new Logger(ResendMailSender.name);

  constructor(private readonly config: ConfigService) {
    super();
  }

  async send(input: MailSendInput): Promise<void> {
    const apiKey = this.config.get<string>('RESEND_API_KEY');
    const fromEmail = this.config.get<string>('RESEND_FROM_EMAIL');
    // allow-list: ローカル開発用フォールバック出力を許すのは development/test のときだけ。
    // NODE_ENV 未設定・typo・staging 等はすべて「本番相当」として fail closed にする
    // （deny-list だと NODE_ENV が欠落しただけでリセットコードがログに残ってしまう）。
    const isLocalDev =
      process.env.NODE_ENV === 'development' || process.env.NODE_ENV === 'test';

    if (!apiKey) {
      if (!isLocalDev) {
        // 本文（コード等の秘密情報）はログに出さない
        throw new AppError(ErrorCode.INTERNAL, 'mail sender is not configured');
      }
      // development/test のみ: ローカル開発用にコンソール出力してフォールバックする
      this.logger.warn(
        `RESEND_API_KEY 未設定のためメール送信をスキップしました: to=${input.to} subject=${input.subject}`,
      );
      this.logger.warn(input.text);
      return;
    }

    const resend = new Resend(apiKey);
    const { error } = await resend.emails.send({
      from: fromEmail ?? 'no-reply@example.com',
      to: input.to,
      subject: input.subject,
      text: input.text,
    });

    if (error) {
      throw new AppError(ErrorCode.INTERNAL, 'failed to send mail');
    }
  }
}
