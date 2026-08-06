import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Patch,
} from '@nestjs/common';
import { CurrentUser } from '../common/decorators/current-user.decorator';
import { UpdateTourDto } from './dto/update-tour.dto';
import { TourMatrixService } from './tour-matrix.service';
import { ToursService } from './tours.service';

/**
 * api-contract.md §5 Tours。全エンドポイント認証必須 (BE-4、Guard は APP_GUARD 既定)。
 * `POST /v1/tours` は提供しない（作成経路は applications の find-or-create のみ — D9）。
 */
@Controller('tours')
export class ToursController {
  constructor(
    private readonly tours: ToursService,
    private readonly matrix: TourMatrixService,
  ) {}

  @Get()
  async list(@CurrentUser() userId: string) {
    return { items: await this.tours.list(userId) };
  }

  @Get(':id')
  get(@CurrentUser() userId: string, @Param('id') id: string) {
    return this.tours.get(userId, id);
  }

  @Get(':id/matrix')
  getMatrix(@CurrentUser() userId: string, @Param('id') id: string) {
    return this.matrix.buildMatrix(userId, id);
  }

  @Patch(':id')
  update(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body() dto: UpdateTourDto,
  ) {
    return this.tours.update(userId, id, dto);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  async remove(@CurrentUser() userId: string, @Param('id') id: string) {
    await this.tours.remove(userId, id);
  }
}
