import { MailSendInput } from '../mail/mail.sender';
import { RESET_CODE_TTL_MINUTES } from './reset-code.generator';

/**
 * パスワード再設定メールの件名・本文（FR-PR-5）。
 * コードと有効期限だけを載せ、会員番号・名義名などの個人情報は載せない（AC-PR-05）。
 */
export function buildPasswordResetMail(
  code: string,
): Omit<MailSendInput, 'to'> {
  return {
    subject: '【参戦名義帳】パスワード再設定のご案内',
    text: [
      'パスワード再設定の確認コードをお知らせします。',
      '',
      `確認コード: ${code}`,
      `有効期限: 発行から ${RESET_CODE_TTL_MINUTES} 分`,
      '',
      'アプリの画面に上記のコードを入力して、新しいパスワードを設定してください。',
      'お心当たりが無い場合は、このメールを破棄してください。パスワードは変更されません。',
    ].join('\n'),
  };
}
