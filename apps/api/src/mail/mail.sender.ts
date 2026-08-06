export interface MailSendInput {
  to: string;
  subject: string;
  text: string;
}

/**
 * メール送信の DI トークン兼インターフェース。
 * `AppleTokenVerifier`（apps/api/src/auth/apple-token.verifier.ts）と同じ形。
 * spec ではスタブに差し替え、jest からネットワークに出ない（NFR-3 / FR-PR-9）。
 */
export abstract class MailSender {
  abstract send(input: MailSendInput): Promise<void>;
}
