import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Patch,
} from '@nestjs/common';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { ThrottleAuthUser } from '../common/throttling/throttle-route.decorators';
import { DeleteMeDto } from './dto/delete-me.dto';
import { UpdateMeDto } from './dto/update-me.dto';
import { MeService, MeView } from './me.service';
import { DeleteMeUseCase } from './use-cases/delete-me.use-case';

/**
 * `GET/PATCH/DELETE /v1/me`（api-contract.md §2 + account-deletion/api-contract-delta.md §1）。
 * すべて認証必須（JwtAuthGuard 既定適用）。`@Public()` を付けないこと（BE-4）。
 */
@Controller('me')
export class MeController {
  constructor(
    private readonly meService: MeService,
    private readonly deleteMeUseCase: DeleteMeUseCase,
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
}
