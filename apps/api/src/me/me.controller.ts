import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Patch,
  Put,
  UploadedFile,
  UseInterceptors,
} from '@nestjs/common';
import { FileInterceptor } from '@nestjs/platform-express';
import { memoryStorage } from 'multer';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { ThrottleAuthUser } from '../common/throttling/throttle-route.decorators';
import { DeleteMeDto } from './dto/delete-me.dto';
import { UpdateMeDto } from './dto/update-me.dto';
import { AVATAR_MAX_BYTES } from './avatar/avatar-image.processor';
import { MeService, MeView } from './me.service';
import { DeleteAvatarUseCase } from './use-cases/delete-avatar.use-case';
import { DeleteMeUseCase } from './use-cases/delete-me.use-case';
import { UploadAvatarUseCase } from './use-cases/upload-avatar.use-case';

/**
 * multer オプション（storage-design.md §4.3）。
 * fileSize に +1 を加えるのは busboy の `fileSize === fileSizeLimit` 判定への対応:
 * ちょうど AVATAR_MAX_BYTES のファイルが通り、それを超えると 413 になる。
 * parts: 2 は 1 ファイル（初期境界 + 終端境界 = 2 境界）を許容する値。
 * busboy は境界ごとに parts カウンタをインクリメントするため parts: 1 は常に LIMIT_PART_COUNT になる。
 */
const AVATAR_UPLOAD_OPTIONS = {
  storage: memoryStorage(),
  limits: {
    fileSize: AVATAR_MAX_BYTES + 1,
    files: 1,
    fields: 0,
    parts: 2,
  },
};

/**
 * `GET/PATCH/DELETE /v1/me`（api-contract.md §2 + account-deletion/api-contract-delta.md §1）。
 * `PUT/DELETE /v1/me/avatar`（avatar-upload/api-contract-delta.md §2・§3）。
 * すべて認証必須（JwtAuthGuard 既定適用）。`@Public()` を付けないこと（BE-4）。
 */
@Controller('me')
export class MeController {
  constructor(
    private readonly meService: MeService,
    private readonly deleteMeUseCase: DeleteMeUseCase,
    private readonly uploadAvatarUseCase: UploadAvatarUseCase,
    private readonly deleteAvatarUseCase: DeleteAvatarUseCase,
  ) {}

  @Get()
  getMe(@CurrentUser() userId: string): Promise<MeView> {
    return this.meService.getMe(userId);
  }

  @Patch()
  updateMe(
    @CurrentUser() userId: string,
    @Body() dto: UpdateMeDto,
  ): Promise<MeView> {
    return this.meService.updateMe(userId, dto);
  }

  /** アカウント削除。204 / ボディ無し。userId 単位で 10 回 5 分（NFR-AD-5）。 */
  @ThrottleAuthUser()
  @Delete()
  @HttpCode(HttpStatus.NO_CONTENT)
  deleteMe(
    @CurrentUser() userId: string,
    @Body() dto: DeleteMeDto,
  ): Promise<void> {
    return this.deleteMeUseCase.execute(userId, dto);
  }

  /** アバター設定。multipart/form-data, field: file。userId 単位 10 回/5 分（§0.3）。 */
  @ThrottleAuthUser()
  @Put('avatar')
  @UseInterceptors(FileInterceptor('file', AVATAR_UPLOAD_OPTIONS))
  uploadAvatar(
    @CurrentUser() userId: string,
    @UploadedFile() file?: Express.Multer.File,
  ): Promise<MeView> {
    return this.uploadAvatarUseCase.execute(userId, file);
  }

  /** アバター削除。冪等。userId 単位 10 回/5 分（§0.3）。 */
  @ThrottleAuthUser()
  @Delete('avatar')
  deleteAvatar(@CurrentUser() userId: string): Promise<MeView> {
    return this.deleteAvatarUseCase.execute(userId);
  }
}
