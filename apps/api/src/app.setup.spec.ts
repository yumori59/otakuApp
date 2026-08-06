import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { AppModule } from './app.module';
import { configureApp } from './app.setup';
import { PrismaService } from './prisma/prisma.service';

describe('bootstrap configuration', () => {
  let app: INestApplication;

  beforeAll(async () => {
    const prismaMock = {
      $connect: jest.fn().mockResolvedValue(undefined),
      $disconnect: jest.fn().mockResolvedValue(undefined),
      $queryRaw: jest.fn().mockResolvedValue([{ '?column?': 1 }]),
      entitlement: { findUnique: jest.fn() },
    };

    const moduleRef = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(PrismaService)
      .useValue(prismaMock)
      .compile();

    app = configureApp(moduleRef.createNestApplication());
    await app.init();
  });

  afterAll(async () => {
    await app?.close();
  });

  it('AC-CORE-04 /health は /v1 の外かつ Bearer 無しで 200', async () => {
    const res = await request(app.getHttpServer()).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });

  it('AC-CORE-04 /readyz は /v1 の外かつ Bearer 無しで 200', async () => {
    const res = await request(app.getHttpServer()).get('/readyz');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'ready', database: 'connected' });
  });

  it('/v1/health は存在しない（exclude が効いている）', async () => {
    const res = await request(app.getHttpServer()).get('/v1/health');
    expect(res.status).toBe(404);
  });

  it('AC-CORE-01 未定義ルートも envelope 形式で返る', async () => {
    const res = await request(app.getHttpServer())
      .get('/v1/does-not-exist')
      .set('X-Request-Id', '018f3c2a-9999-7c90-9d2a-000000000001');

    expect(res.status).toBe(404);
    expect(Object.keys(res.body).sort()).toEqual([
      'code',
      'details',
      'message',
      'request_id',
    ]);
    expect(res.body.code).toBe('NOT_FOUND');
    expect(res.body.request_id).toBe('018f3c2a-9999-7c90-9d2a-000000000001');
    expect(res.headers['x-request-id']).toBe(
      '018f3c2a-9999-7c90-9d2a-000000000001',
    );
  });
});
