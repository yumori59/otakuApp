import { INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { Test } from '@nestjs/testing';
import { ThrottlerModule } from '@nestjs/throttler';
import request from 'supertest';
import {
  GLOBAL_PREFIX,
  GLOBAL_PREFIX_EXCLUDE,
  configureApp,
} from '../app.setup';
import { IS_PUBLIC_KEY } from '../common/decorators/public.decorator';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { JwtAuthGuard } from '../common/guards/jwt-auth.guard';
import { THROTTLER_CONFIG } from '../common/throttling/throttler-config';
import { PublicController } from './public.controller';
import { ResolveShareUseCase } from './use-cases/resolve-share.use-case';
import { UpdateShareItemUseCase } from './use-cases/update-share-item.use-case';

const PAYLOAD = {
  scope_type: 'tour',
  permission: 'read',
  tour: { name: 'STELLARIS LIVE TOUR 2026', artist_name: 'STELLARIS' },
  generated_at: '2026-08-02T10:00:00.000Z',
  items: [],
};

const ITEM = {
  event_name: '大阪公演 Day1',
  venue: '大阪城ホール',
  event_date: '2026-08-20',
  round_name: 'FC1次',
  rep_name: '自分',
  rep_color: '#0017C1',
  companions: ['妹'],
  status: 'won',
  seat: '1F A列 12番',
  item_key: 'b3RhLWtleS1zYW1wbGUx',
  rev: 'bmV3LXJldi12YWx1ZQ',
  editable: true,
};

const TOKEN = 'raw-opaque-share-token';
const ITEM_KEY = 'b3RhLWtleS1zYW1wbGUx';
const PATCH_PATH = `/public/shares/${TOKEN}/items/${ITEM_KEY}`;
/** app.setup.ts の GLOBAL_PREFIX_EXCLUDE に必要なエントリ（T0 所管の変更）。 */
const PATCH_ROUTE = 'public/shares/:token/items/:item_key';

/**
 * `GLOBAL_PREFIX_EXCLUDE` への PATCH ルート追加は app.setup.ts 側の変更（T2 は編集しない）。
 * まだ入っていない環境でも契約どおりのパスで検証できるよう、ここで重複なく足す。
 */
function configurePublicApp(app: INestApplication): INestApplication {
  configureApp(app);
  app.setGlobalPrefix(GLOBAL_PREFIX, {
    exclude: [...new Set([...GLOBAL_PREFIX_EXCLUDE, PATCH_ROUTE])],
  });
  return app;
}

describe('PublicController', () => {
  let app: INestApplication;
  let resolveShare: { execute: jest.Mock };
  let updateShareItem: { execute: jest.Mock };

  beforeEach(async () => {
    resolveShare = { execute: jest.fn().mockResolvedValue(PAYLOAD) };
    updateShareItem = { execute: jest.fn().mockResolvedValue(ITEM) };

    const moduleRef = await Test.createTestingModule({
      // TokenThrottlerGuard (share-write) が依存する storage / options を用意する
      imports: [ThrottlerModule.forRoot(THROTTLER_CONFIG)],
      controllers: [PublicController],
      providers: [
        { provide: ResolveShareUseCase, useValue: resolveShare },
        { provide: UpdateShareItemUseCase, useValue: updateShareItem },
        { provide: JwtService, useValue: { verifyAsync: jest.fn() } },
        { provide: ConfigService, useValue: { get: jest.fn() } },
        // 本番同様に APP_GUARD を効かせた状態で @Public() の素通しを確かめる
        { provide: APP_GUARD, useClass: JwtAuthGuard },
      ],
    }).compile();

    app = configurePublicApp(moduleRef.createNestApplication());
    await app.init();
  });

  afterEach(async () => {
    await app?.close();
  });

  it('AC-SH-19 ハンドラに @Public() が付いている（意図的公開 — BE-4）', () => {
    expect(
      Reflect.getMetadata(IS_PUBLIC_KEY, PublicController.prototype.getShare),
    ).toBe(true);
  });

  it('AC-SH-19 GET /public/shares/:token は Bearer 無しで 200（/v1 を付けない）', async () => {
    const res = await request(app.getHttpServer()).get(
      '/public/shares/raw-opaque-share-token',
    );

    expect(res.status).toBe(200);
    expect(res.body).toEqual(PAYLOAD);
    expect(resolveShare.execute).toHaveBeenCalledWith('raw-opaque-share-token');
  });

  it('AC-SH-19 /v1/public/shares/:token は存在しない', async () => {
    const res = await request(app.getHttpServer()).get(
      '/v1/public/shares/raw-opaque-share-token',
    );

    expect(res.status).toBe(404);
  });

  it('AC-SH-20 レスポンスに X-Robots-Tag: noindex, nofollow が付く', async () => {
    const res = await request(app.getHttpServer()).get(
      '/public/shares/raw-opaque-share-token',
    );

    expect(res.headers['x-robots-tag']).toBe('noindex, nofollow');
  });

  it('AC-SH-20 SHARE_INVALID 404 のときも X-Robots-Tag が付く', async () => {
    resolveShare.execute.mockRejectedValue(
      new AppError(ErrorCode.SHARE_INVALID, 'share link is invalid'),
    );

    const res = await request(app.getHttpServer()).get(
      '/public/shares/unknown-token',
    );

    expect(res.status).toBe(404);
    expect(res.body.code).toBe(ErrorCode.SHARE_INVALID);
    expect(res.headers['x-robots-tag']).toBe('noindex, nofollow');
  });

  describe('PATCH /public/shares/:token/items/:item_key', () => {
    it('ハンドラに @Public() が付いている（意図的公開 — BE-4）', () => {
      expect(
        Reflect.getMetadata(
          IS_PUBLIC_KEY,
          PublicController.prototype.patchShareItem,
        ),
      ).toBe(true);
    });

    it('AC-SW-11 Bearer 無しで 200・token / item_key / body を use-case に渡す', async () => {
      const res = await request(app.getHttpServer())
        .patch(PATCH_PATH)
        .send({ rev: 'cmV2LXNhbXBsZQ', status: 'won' });

      expect(res.status).toBe(200);
      expect(res.body).toEqual(ITEM);
      expect(updateShareItem.execute).toHaveBeenCalledWith(TOKEN, ITEM_KEY, {
        rev: 'cmV2LXNhbXBsZQ',
        status: 'won',
      });
    });

    it('AC-SW-26 レスポンスに X-Robots-Tag: noindex, nofollow が付く', async () => {
      const res = await request(app.getHttpServer())
        .patch(PATCH_PATH)
        .send({ rev: 'cmV2LXNhbXBsZQ', status: 'won' });

      expect(res.headers['x-robots-tag']).toBe('noindex, nofollow');
    });

    it('AC-SW-19 契約外のキー（round_name / note / ticket_count / companions）は 400', async () => {
      for (const extra of [
        { round_name: 'FC2次' },
        { note: 'メモ' },
        { ticket_count: 2 },
        { companions: [] },
      ]) {
        const res = await request(app.getHttpServer())
          .patch(PATCH_PATH)
          .send({ rev: 'cmV2LXNhbXBsZQ', status: 'won', ...extra });

        expect(res.status).toBe(400);
        expect(res.body.code).toBe(ErrorCode.VALIDATION_ERROR);
      }
      expect(updateShareItem.execute).not.toHaveBeenCalled();
    });

    it('AC-SW-19 status / seat が無いボディは 400', async () => {
      const res = await request(app.getHttpServer())
        .patch(PATCH_PATH)
        .send({ rev: 'cmV2LXNhbXBsZQ' });

      expect(res.status).toBe(400);
      expect(updateShareItem.execute).not.toHaveBeenCalled();
    });

    it('AC-SW-19 未知の status は 400', async () => {
      const res = await request(app.getHttpServer())
        .patch(PATCH_PATH)
        .send({ rev: 'cmV2LXNhbXBsZQ', status: 'approved' });

      expect(res.status).toBe(400);
      expect(updateShareItem.execute).not.toHaveBeenCalled();
    });

    it('AppError はそのまま envelope で返る（409 + details.current）', async () => {
      updateShareItem.execute.mockRejectedValue(
        AppError.conflict('share item was updated by someone else', {
          current: { status: 'lost', seat: null, rev: 'Y3VycmVudC1yZXY' },
        }),
      );

      const res = await request(app.getHttpServer())
        .patch(PATCH_PATH)
        .send({ rev: 'cmV2LXNhbXBsZQ', status: 'won' });

      expect(res.status).toBe(409);
      expect(res.body.code).toBe(ErrorCode.CONFLICT);
      expect(res.body.details.current.rev).toBe('Y3VycmVudC1yZXY');
    });

    it('AC-SW-27 同一 token へ上限（60 回/分）を超えると RATE_LIMITED 429', async () => {
      const send = () =>
        request(app.getHttpServer())
          .patch(PATCH_PATH)
          .send({ rev: 'cmV2LXNhbXBsZQ', status: 'won' });

      for (let i = 0; i < 60; i += 1) {
        expect((await send()).status).toBe(200);
      }

      const limited = await send();
      expect(limited.status).toBe(429);
      expect(limited.body.code).toBe(ErrorCode.RATE_LIMITED);
    });

    it('AC-SW-27 token が違えばカウントを共有しない（tracker は token 単位）', async () => {
      const send = (token: string) =>
        request(app.getHttpServer())
          .patch(`/public/shares/${token}/items/${ITEM_KEY}`)
          .send({ rev: 'cmV2LXNhbXBsZQ', status: 'won' });

      for (let i = 0; i < 60; i += 1) {
        await send('token-a');
      }

      expect((await send('token-b')).status).toBe(200);
    });
  });
});
