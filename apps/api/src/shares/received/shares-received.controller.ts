import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
  Post,
  UseGuards,
} from '@nestjs/common';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { ThrottleShareWrite } from '../../common/throttling/throttle-route.decorators';
import { UpdateShareItemDto } from '../board/dto/update-share-item.dto';
import { RedeemShareDto } from './dto/redeem-share.dto';
import { RedeemThrottlerGuard } from './redeem-throttler.guard';
import { GetBoardUseCase } from './use-cases/get-board.use-case';
import { ListInboxUseCase } from './use-cases/list-inbox.use-case';
import { RedeemShareUseCase } from './use-cases/redeem-share.use-case';
import { SetHiddenUseCase } from './use-cases/set-hidden.use-case';
import { UpdateItemUseCase } from './use-cases/update-item.use-case';

/**
 * 受け取り側の共有 API（api-contract-delta.md §4）。
 * 全ルート Bearer 必須。`@Public()` を付けない（BE-4。JwtAuthGuard は APP_GUARD 既定）。
 */
@Controller('shares/received')
export class SharesReceivedController {
  constructor(
    private readonly listInbox: ListInboxUseCase,
    private readonly getBoard: GetBoardUseCase,
    private readonly redeemShare: RedeemShareUseCase,
    private readonly setHidden: SetHiddenUseCase,
    private readonly updateItem: UpdateItemUseCase,
  ) {}

  @Get()
  list(@CurrentUser() userId: string) {
    return this.listInbox.execute(userId).then((items) => ({ items }));
  }

  @Post('redeem')
  @HttpCode(HttpStatus.OK)
  @UseGuards(RedeemThrottlerGuard)
  redeem(@CurrentUser() userId: string, @Body() dto: RedeemShareDto) {
    return this.redeemShare.execute(userId, dto.token);
  }

  @Get(':id')
  get(@CurrentUser() userId: string, @Param('id') id: string) {
    return this.getBoard.execute(userId, id);
  }

  /**
   * 軽量共同編集（api-contract-delta.md §4.3）。60 回/分・userId + share_id 単位（§0.3）。
   * 判定順序（招待判定は permission 判定より前）は `UpdateItemUseCase` が持つ。
   */
  @Patch(':id/items/:item_key')
  @ThrottleShareWrite()
  update(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Param('item_key') itemKey: string,
    @Body() dto: UpdateShareItemDto,
  ) {
    return this.updateItem.execute(userId, id, itemKey, dto);
  }

  @Post(':id/hide')
  @HttpCode(HttpStatus.NO_CONTENT)
  async hide(@CurrentUser() userId: string, @Param('id') id: string) {
    await this.setHidden.execute(userId, id, true);
  }

  @Delete(':id/hide')
  @HttpCode(HttpStatus.NO_CONTENT)
  async unhide(@CurrentUser() userId: string, @Param('id') id: string) {
    await this.setHidden.execute(userId, id, false);
  }
}
