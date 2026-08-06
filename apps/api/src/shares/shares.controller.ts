import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Post,
} from '@nestjs/common';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { CreateShareDto } from './dto/create-share.dto';
import { SharesService } from './shares.service';
import { CreateShareUseCase } from './use-cases/create-share.use-case';

/**
 * api-contract.md §8 Shares。全エンドポイント認証必須（Guard は APP_GUARD 既定・BE-4）。
 * `@Public()` を付けないこと — 公開経路は `/public/shares/:token` のみ。
 */
@Controller('shares')
export class SharesController {
  constructor(
    private readonly createShare: CreateShareUseCase,
    private readonly shares: SharesService,
  ) {}

  @Post()
  @HttpCode(HttpStatus.CREATED)
  create(@CurrentUser() userId: string, @Body() dto: CreateShareDto) {
    return this.createShare.execute(userId, dto);
  }

  @Get()
  list(@CurrentUser() userId: string) {
    return this.shares.list(userId).then((items) => ({ items }));
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  async remove(@CurrentUser() userId: string, @Param('id') id: string) {
    await this.shares.revoke(userId, id);
  }
}
