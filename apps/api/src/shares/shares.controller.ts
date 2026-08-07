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
import { AddRecipientsDto } from './dto/add-recipients.dto';
import { CreateShareDto } from './dto/create-share.dto';
import { ThrottleShareInvite } from './throttle-share-invite.decorator';
import { SharesService } from './shares.service';
import { AddRecipientsUseCase } from './use-cases/add-recipients.use-case';
import { CreateShareUseCase } from './use-cases/create-share.use-case';
import { RemoveRecipientUseCase } from './use-cases/remove-recipient.use-case';

/**
 * api-contract-delta.md §1〜§3 Shares（オーナー側）。全エンドポイント認証必須（Guard は APP_GUARD 既定・BE-4）。
 * `@Public()` を付けないこと — 公開経路は Q1=A で完全廃止済み。
 */
@Controller('shares')
export class SharesController {
  constructor(
    private readonly createShare: CreateShareUseCase,
    private readonly addRecipients: AddRecipientsUseCase,
    private readonly removeRecipient: RemoveRecipientUseCase,
    private readonly shares: SharesService,
  ) {}

  @Post()
  @HttpCode(HttpStatus.CREATED)
  @ThrottleShareInvite()
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

  @Post(':id/recipients')
  @HttpCode(HttpStatus.OK)
  @ThrottleShareInvite()
  addRecipientsToShare(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body() dto: AddRecipientsDto,
  ) {
    return this.addRecipients.execute(userId, id, dto);
  }

  @Delete(':id/recipients/:account_id')
  @HttpCode(HttpStatus.NO_CONTENT)
  async removeRecipientFromShare(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Param('account_id') accountId: string,
  ) {
    await this.removeRecipient.execute(userId, id, accountId);
  }
}
