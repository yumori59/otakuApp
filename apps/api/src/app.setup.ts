import { INestApplication, ValidationPipe } from '@nestjs/common';
import { AllExceptionsFilter } from './common/filters/all-exceptions.filter';

export const GLOBAL_PREFIX = 'v1';

/** /v1 を付けないルート（api-contract.md §0）。 */
export const GLOBAL_PREFIX_EXCLUDE = ['health', 'readyz'];

/** ValidationPipe に渡すオプション。DTO spec からも同じ設定を参照する。 */
export const GLOBAL_VALIDATION_OPTIONS = {
  whitelist: true,
  forbidNonWhitelisted: true,
  transform: true,
};

/**
 * main.ts と spec で同じグローバル設定を使うための共通化。
 * CORS は起動時のみの設定なので main.ts に置く。
 */
export function configureApp(app: INestApplication): INestApplication {
  app.setGlobalPrefix(GLOBAL_PREFIX, { exclude: GLOBAL_PREFIX_EXCLUDE });

  app.useGlobalPipes(new ValidationPipe(GLOBAL_VALIDATION_OPTIONS));

  app.useGlobalFilters(new AllExceptionsFilter());

  return app;
}
