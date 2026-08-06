import { Controller, Get } from '@nestjs/common';
import { Public } from '../common/decorators/public.decorator';
import { PrismaService } from '../prisma/prisma.service';

@Public()
@Controller()
export class HealthController {
  constructor(private readonly prisma: PrismaService) {}

  @Get('health')
  health() {
    return { status: 'ok' };
  }

  @Get('readyz')
  async readyz() {
    await this.prisma.$queryRaw`SELECT 1`;
    return { status: 'ready', database: 'connected' };
  }
}
