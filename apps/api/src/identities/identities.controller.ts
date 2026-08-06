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
  Query,
} from '@nestjs/common';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { CreateIdentityDto } from './dto/create-identity.dto';
import { ListIdentitiesQueryDto } from './dto/list-identities-query.dto';
import { UpdateIdentityDto } from './dto/update-identity.dto';
import { IdentitiesService } from './identities.service';

/** api-contract.md §3 Identities。全エンドポイント認証必須 (BE-4、Guard は APP_GUARD 既定)。 */
@Controller('identities')
export class IdentitiesController {
  constructor(private readonly identities: IdentitiesService) {}

  @Get()
  list(
    @CurrentUser() userId: string,
    @Query() query: ListIdentitiesQueryDto,
  ) {
    return this.identities
      .list(userId, query.include_deleted ?? false)
      .then((items) => ({ items }));
  }

  @Post()
  @HttpCode(HttpStatus.CREATED)
  create(@CurrentUser() userId: string, @Body() dto: CreateIdentityDto) {
    return this.identities.create(userId, dto);
  }

  @Get(':id')
  get(@CurrentUser() userId: string, @Param('id') id: string) {
    return this.identities.get(userId, id);
  }

  @Patch(':id')
  update(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body() dto: UpdateIdentityDto,
  ) {
    return this.identities.update(userId, id, dto);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  async remove(@CurrentUser() userId: string, @Param('id') id: string) {
    await this.identities.remove(userId, id);
  }
}
