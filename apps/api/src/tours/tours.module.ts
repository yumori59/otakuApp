import { Module } from '@nestjs/common';
import { TourMatrixService } from './tour-matrix.service';
import { ToursController } from './tours.controller';
import { ToursService } from './tours.service';

/**
 * ToursService は applications (T5) の find-or-create が、
 * TourMatrixService は shares / public (T6) がマスキング付きで再利用するため export する。
 */
@Module({
  controllers: [ToursController],
  providers: [ToursService, TourMatrixService],
  exports: [ToursService, TourMatrixService],
})
export class ToursModule {}
