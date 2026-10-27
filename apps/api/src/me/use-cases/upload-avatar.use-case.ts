import { Injectable, Logger } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AvatarImageProcessor } from '../avatar/avatar-image.processor';
import { AvatarService } from '../avatar/avatar.service';
import { AvatarStorage } from '../avatar/avatar.storage';
import { MeService, MeView } from '../me.service';

/**
 * `PUT /v1/me/avatar`（avatar-upload/api-contract-delta.md §2）。
 * 対象は常に引数の `userId`（Bearer の `sub`）。Prisma には触れない（BE-3）。
 * ログに URL・キーを出さない（NFR-AV-7）。
 */
@Injectable()
export class UploadAvatarUseCase {
  private readonly logger = new Logger(UploadAvatarUseCase.name);

  constructor(
    private readonly processor: AvatarImageProcessor,
    private readonly storage: AvatarStorage,
    private readonly avatarService: AvatarService,
    private readonly meService: MeService,
  ) {}

  async execute(
    userId: string,
    file?: Express.Multer.File,
  ): Promise<MeView> {
    // 1. file が無い → VALIDATION_ERROR
    if (!file) {
      throw new AppError(ErrorCode.VALIDATION_ERROR, 'file is required');
    }

    // 2. ストレージ未設定 → SERVICE_UNAVAILABLE（アップロード前に判定）
    if (!this.storage.isConfigured()) {
      throw new AppError(
        ErrorCode.SERVICE_UNAVAILABLE,
        'avatar is temporarily unavailable',
      );
    }

    // 3. テーブル存在確認を兼ねる（P2021 → 503）
    await this.avatarService.findObjectKeyOrUnavailable(userId);

    // 4. 画像処理（マジックバイト検証・再エンコード）
    const jpeg = await this.processor.process(file.buffer);

    // 5. GCS に保存（失敗 → 例外のまま 500）
    const key = `avatars/${randomUUID()}.jpg`;
    await this.storage.put(key, jpeg);

    // 6. DB upsert（失敗 → 新オブジェクトを補償削除して再スロー）
    let previousKey: string | null = null;
    try {
      const result = await this.avatarService.replace(userId, key);
      previousKey = result.previousKey;
    } catch (err) {
      await this.storage.delete(key).catch(() => {
        this.logger.warn(
          `補償削除に失敗しました user_id=${userId}`,
        );
      });
      throw err;
    }

    // 7. 旧オブジェクト削除（ベストエフォート）
    if (previousKey) {
      await this.storage.delete(previousKey).catch(() => {
        this.logger.warn(
          `旧アバターの削除に失敗しました user_id=${userId}`,
        );
      });
    }

    return this.meService.getMe(userId);
  }
}
