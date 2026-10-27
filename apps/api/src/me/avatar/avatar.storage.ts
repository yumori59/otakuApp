/**
 * アバター画像のストレージ DI トークン兼インターフェース。
 * `MailSender`（apps/api/src/mail/mail.sender.ts）と同じ形。
 * spec ではスタブに差し替え、jest から外部ストレージに出ない。
 */
export abstract class AvatarStorage {
  /** AVATAR_BUCKET が設定されているか。 */
  abstract isConfigured(): boolean;

  /** contentType / cacheControl は契約（api-contract-delta.md §2）の値を実装側で固定する。 */
  abstract put(objectKey: string, jpeg: Buffer): Promise<void>;

  /** 存在しない（404）は成功扱い。 */
  abstract delete(objectKey: string): Promise<void>;

  /** 未設定なら null。 */
  abstract publicUrl(objectKey: string): string | null;
}
