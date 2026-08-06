import { Global, Module } from '@nestjs/common';
import { MailSender } from './mail.sender';
import { ResendMailSender } from './resend.mail.sender';

/**
 * auth（パスワードリセット）から参照される。各モジュールが import 行を
 * 足さずに使えるよう @Global にしている（EntitlementsModule と同じ形）。
 */
@Global()
@Module({
  providers: [{ provide: MailSender, useClass: ResendMailSender }],
  exports: [MailSender],
})
export class MailModule {}
