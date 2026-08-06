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
import { ApplicationsService } from './applications.service';
import { CreateApplicationDto } from './dto/create-application.dto';
import { ListApplicationsQueryDto } from './dto/list-applications-query.dto';
import { UpdateApplicationDto } from './dto/update-application.dto';
import { CreateApplicationUseCase } from './use-cases/create-application.use-case';
import { UpdateApplicationUseCase } from './use-cases/update-application.use-case';

/** api-contract.md §7 Applications。全エンドポイント認証必須 (BE-4)。 */
@Controller('applications')
export class ApplicationsController {
  constructor(
    private readonly applications: ApplicationsService,
    private readonly createApplication: CreateApplicationUseCase,
    private readonly updateApplication: UpdateApplicationUseCase,
  ) {}

  @Get()
  list(
    @CurrentUser() userId: string,
    @Query() query: ListApplicationsQueryDto,
  ) {
    return this.applications.list(userId, query);
  }

  @Post()
  @HttpCode(HttpStatus.CREATED)
  create(@CurrentUser() userId: string, @Body() dto: CreateApplicationDto) {
    return this.createApplication.execute(userId, dto);
  }

  @Get(':id')
  get(@CurrentUser() userId: string, @Param('id') id: string) {
    return this.applications.get(userId, id);
  }

  @Patch(':id')
  update(
    @CurrentUser() userId: string,
    @Param('id') id: string,
    @Body() dto: UpdateApplicationDto,
  ) {
    return this.updateApplication.execute(userId, id, dto);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  async remove(@CurrentUser() userId: string, @Param('id') id: string) {
    await this.applications.remove(userId, id);
  }
}
