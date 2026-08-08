import { INestApplication, ValidationPipe } from '@nestjs/common';
import { AllExceptionsFilter } from './common/filters/all-exceptions.filter';

export const GLOBAL_PREFIX = 'v1';

/** /v1 を付けないルート（api-contract.md §0）。 */
export const GLOBAL_PREFIX_EXCLUDE = ['health', 'readyz'];

/**
 * main.ts と spec で同じグローバル設定を使うための共通化。
 * CORS は起動時のみの設定なので main.ts に置く。
 */
export function configureApp(app: INestApplication): INestApplication {
  app.setGlobalPrefix(GLOBAL_PREFIX, { exclude: GLOBAL_PREFIX_EXCLUDE });

  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      forbidNonWhitelisted: true,
      transform: true,
    }),
  );

  app.useGlobalFilters(new AllExceptionsFilter());

  return app;
}
