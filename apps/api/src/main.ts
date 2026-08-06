import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { configureApp } from './app.setup';

async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  // グローバルプレフィックス /v1・ValidationPipe・AllExceptionsFilter
  configureApp(app);

  const corsOrigins = (process.env.CORS_ORIGINS ?? '')
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);
  if (corsOrigins.length > 0) {
    app.enableCors({ origin: corsOrigins });
  }

  const port = Number(process.env.PORT ?? 8080);
  await app.listen(port);
  console.log(`Meigicho API listening on http://0.0.0.0:${port}`);
}
bootstrap();
