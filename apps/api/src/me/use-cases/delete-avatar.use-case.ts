import { Injectable, Logger } from '@nestjs/common';
import { AvatarService } from '../avatar/avatar.service';
import { AvatarStorage } from '../avatar/avatar.storage';
import { MeService, MeView } from '../me.service';

/**
 * `DELETE /v1/me/avatar`（avatar-upload/api-contract-delta.md §3）。
 * 冪等。未設定でも 200。ログに URL・キーを出さない（NFR-AV-7）。
 * Prisma には触れない（BE-3）。
 */
@Injectable()
export class DeleteAvatarUseCase {
  private readonly logger = new Logger(DeleteAvatarUseCase.name);

  constructor(
    private readonly avatarService: AvatarService,
    private readonly storage: AvatarStorage,
    private readonly meService: MeService,
  ) {}

  async execute(userId: string): Promise<MeView> {
    const { previousKey } = await this.avatarService.remove(userId);

    if (previousKey && this.storage.isConfigured()) {
      await this.storage.delete(previousKey).catch(() => {
        this.logger.warn(
          `アバターのオブジェクト削除に失敗しました user_id=${userId}`,
        );
      });
    } else if (previousKey && !this.storage.isConfigured()) {
      this.logger.warn(
        `AVATAR_BUCKET 未設定のためオブジェクト削除をスキップしました user_id=${userId}`,
      );
    }

    return this.meService.getMe(userId);
  }
}
