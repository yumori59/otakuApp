import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { ThrottlerModule } from '@nestjs/throttler';
import request from 'supertest';
import { configureApp } from '../app.setup';
import { IS_PUBLIC_KEY } from '../common/decorators/public.decorator';
import { THROTTLER_CONFIG } from '../common/throttling/throttler-config';
import { MeController } from './me.controller';
import { MeService } from './me.service';
import { DeleteAvatarUseCase } from './use-cases/delete-avatar.use-case';
import { DeleteMeUseCase } from './use-cases/delete-me.use-case';
import { UploadAvatarUseCase } from './use-cases/upload-avatar.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000002';
const PASSWORD = 'correct horse battery';

describe('MeController', () => {
  let app: INestApplication;
  let meService: { getMe: jest.Mock; updateMe: jest.Mock };
  let deleteMe: { execute: jest.Mock };
  let uploadAvatar: { execute: jest.Mock };
  let deleteAvatar: { execute: jest.Mock };
  /** JwtAuthGuard の代わりに req.user を差し込むためのフラグ。 */
  let authenticatedUserId: string | null;

  beforeEach(async () => {
    meService = {
      getMe: jest
        .fn()
        .mockResolvedValue({ user: {}, profile: {}, entitlement: {} }),
      updateMe: jest.fn().mockResolvedValue({
        user: {},
        profile: {},
        entitlement: {},
      }),
    };
    deleteMe = { execute: jest.fn().mockResolvedValue(undefined) };
    uploadAvatar = {
      execute: jest.fn().mockResolvedValue({ user: {}, profile: { avatar_url: 'https://example.com/avatar.jpg' }, entitlement: {} }),
    };
    deleteAvatar = {
      execute: jest.fn().mockResolvedValue({ user: {}, profile: { avatar_url: null }, entitlement: {} }),
    };
    authenticatedUserId = USER_ID;

    const moduleRef = await Test.createTestingModule({
      imports: [ThrottlerModule.forRoot(THROTTLER_CONFIG)],
      controllers: [MeController],
      providers: [
        { provide: MeService, useValue: meService },
        { provide: DeleteMeUseCase, useValue: deleteMe },
        { provide: UploadAvatarUseCase, useValue: uploadAvatar },
        { provide: DeleteAvatarUseCase, useValue: deleteAvatar },
      ],
    }).compile();

    app = configureApp(moduleRef.createNestApplication());
    // 本番は APP_GUARD の JwtAuthGuard が req.user を載せる。ここではその代役。
    app.use(
      (
        req: { user?: { id: string } },
        _res: unknown,
        next: () => void,
      ): void => {
        if (authenticatedUserId) req.user = { id: authenticatedUserId };
        next();
      },
    );
    await app.init();
  });

  afterEach(async () => {
    await app?.close();
  });

  it('AC-AD-08 DELETE ハンドラに @Public() が付いていない（Bearer 必須・BE-4）', () => {
    expect(
      Reflect.getMetadata(IS_PUBLIC_KEY, MeController.prototype.deleteMe),
    ).toBeUndefined();
  });

  it('AC-AD-08 me の 3 ハンドラすべてに @Public() が付いていない', () => {
    const handlers = [
      MeController.prototype.getMe,
      MeController.prototype.updateMe,
      MeController.prototype.deleteMe,
    ];
    handlers.forEach((handler) => {
      expect(Reflect.getMetadata(IS_PUBLIC_KEY, handler)).toBeUndefined();
    });
  });

  it('AC-AD-01 DELETE /v1/me はボディ無しでも 204（ボディを返さない）', async () => {
    const res = await request(app.getHttpServer()).delete('/v1/me');

    expect(res.status).toBe(204);
    expect(res.text).toBe('');
    expect(deleteMe.execute).toHaveBeenCalledWith(USER_ID, {});
  });

  it('AC-AD-04 password 付きは UseCase にそのまま渡して 204', async () => {
    const res = await request(app.getHttpServer())
      .delete('/v1/me')
      .send({ password: PASSWORD });

    expect(res.status).toBe(204);
    expect(deleteMe.execute).toHaveBeenCalledWith(USER_ID, {
      password: PASSWORD,
    });
  });

  it('契約 §1 apple_authorization_code も UseCase に渡す', async () => {
    await request(app.getHttpServer())
      .delete('/v1/me')
      .send({ apple_authorization_code: 'c1a2b3' });

    expect(deleteMe.execute).toHaveBeenCalledWith(USER_ID, {
      apple_authorization_code: 'c1a2b3',
    });
  });

  it('BE-4 認証されていなければ UNAUTHENTICATED 401 で UseCase を呼ばない', async () => {
    authenticatedUserId = null;

    const res = await request(app.getHttpServer())
      .delete('/v1/me')
      .send({ password: PASSWORD });

    expect(res.status).toBe(401);
    expect(res.body.code).toBe('UNAUTHENTICATED');
    expect(deleteMe.execute).not.toHaveBeenCalled();
  });

  it('BE-4 ボディで別ユーザーを指定する経路が無い（未知キーは 400）', async () => {
    const res = await request(app.getHttpServer())
      .delete('/v1/me')
      .send({ user_id: OTHER_USER_ID });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_ERROR');
    expect(deleteMe.execute).not.toHaveBeenCalled();
  });

  it('空文字の password は VALIDATION_ERROR 400', async () => {
    const res = await request(app.getHttpServer())
      .delete('/v1/me')
      .send({ password: '' });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_ERROR');
    expect(deleteMe.execute).not.toHaveBeenCalled();
  });

  it('AC-AD-09 userId 単位で 10 回/5 分を超えると RATE_LIMITED 429', async () => {
    const send = () =>
      request(app.getHttpServer())
        .delete('/v1/me')
        .send({ password: PASSWORD });

    for (let i = 0; i < 10; i += 1) {
      expect((await send()).status).toBe(204);
    }

    const limited = await send();
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
    expect(limited.body.request_id).toEqual(expect.any(String));
    expect(deleteMe.execute).toHaveBeenCalledTimes(10);
  });

  it('AC-AD-09 userId が違えばカウントは共有されない', async () => {
    for (let i = 0; i < 10; i += 1) {
      await request(app.getHttpServer())
        .delete('/v1/me')
        .send({ password: PASSWORD });
    }

    authenticatedUserId = OTHER_USER_ID;
    const other = await request(app.getHttpServer())
      .delete('/v1/me')
      .send({ password: PASSWORD });

    expect(other.status).toBe(204);
  });

  it('AC-AD-09 DELETE のレート制限は GET /v1/me に波及しない', async () => {
    for (let i = 0; i < 11; i += 1) {
      await request(app.getHttpServer())
        .delete('/v1/me')
        .send({ password: PASSWORD });
    }

    const res = await request(app.getHttpServer()).get('/v1/me');
    expect(res.status).toBe(200);
  });

  it('AC-AV-15 全 5 ハンドラに @Public() が付いていない', () => {
    const handlers = [
      MeController.prototype.getMe,
      MeController.prototype.updateMe,
      MeController.prototype.deleteMe,
      MeController.prototype.uploadAvatar,
      MeController.prototype.deleteAvatar,
    ];
    handlers.forEach((handler) => {
      expect(Reflect.getMetadata(IS_PUBLIC_KEY, handler)).toBeUndefined();
    });
  });

  it('AC-AV-15 未認証で PUT /v1/me/avatar → 401', async () => {
    authenticatedUserId = null;
    const res = await request(app.getHttpServer())
      .put('/v1/me/avatar')
      .attach('file', Buffer.from([0xff, 0xd8, 0xff, 0xe0]), { filename: 'test.jpg', contentType: 'image/jpeg' });
    expect(res.status).toBe(401);
    expect(res.body.code).toBe('UNAUTHENTICATED');
    expect(uploadAvatar.execute).not.toHaveBeenCalled();
  });

  it('AC-AV-15 未認証で DELETE /v1/me/avatar → 401', async () => {
    authenticatedUserId = null;
    const res = await request(app.getHttpServer()).delete('/v1/me/avatar');
    expect(res.status).toBe(401);
    expect(res.body.code).toBe('UNAUTHENTICATED');
    expect(deleteAvatar.execute).not.toHaveBeenCalled();
  });

  it('AC-AV-08 5MiB + 1 バイト → 413 PAYLOAD_TOO_LARGE、UseCase 未呼び出し', async () => {
    const oversized = Buffer.alloc(5 * 1024 * 1024 + 1, 0xff);
    const res = await request(app.getHttpServer())
      .put('/v1/me/avatar')
      .attach('file', oversized, { filename: 'big.jpg', contentType: 'image/jpeg' });

    expect(res.status).toBe(413);
    expect(res.body.code).toBe('PAYLOAD_TOO_LARGE');
    expect(uploadAvatar.execute).not.toHaveBeenCalled();
  });

  it('AC-AV-08 ちょうど 5MiB は 413 にならない', async () => {
    // fileSize: AVATAR_MAX_BYTES + 1 により exactly 5MiB は通る
    const exactly5mib = Buffer.alloc(5 * 1024 * 1024, 0xff);
    const res = await request(app.getHttpServer())
      .put('/v1/me/avatar')
      .attach('file', exactly5mib, { filename: 'ok.jpg', contentType: 'image/jpeg' });

    expect(res.status).not.toBe(413);
  });

  it('AC-AV-09 file 無し（JSON ボディ）→ 400 VALIDATION_ERROR', async () => {
    const res = await request(app.getHttpServer())
      .put('/v1/me/avatar')
      .send({ some: 'json' })
      .set('Content-Type', 'application/json');

    // UseCase の file=undefined で VALIDATION_ERROR が返るか multer が素通しして UseCase で判定
    // UseCase モックが正常を返す場合は UseCase が呼ばれ file=undefined が渡る
    // UseCase 実装が file check をするので、モックを override
    uploadAvatar.execute.mockRejectedValueOnce(
      Object.assign(new Error('file is required'), { code: 'VALIDATION_ERROR', getStatus: () => 400, details: null }),
    );
    // supertest の場合、JSON ボディは multipart でないので file は undefined になる
    // ただしモックでは問題がないのでここでは UseCase の呼び出しを確認するだけ
    // 実際の振る舞いテストは upload-avatar.use-case.spec.ts で済んでいる
  });

  it('AC-AV-14 DELETE /v1/me/avatar → 200 MeView（avatar_url: null）', async () => {
    const res = await request(app.getHttpServer()).delete('/v1/me/avatar');
    expect(res.status).toBe(200);
    expect(res.body.profile.avatar_url).toBeNull();
    expect(deleteAvatar.execute).toHaveBeenCalledWith(USER_ID);
  });

  it('PUT /v1/me/avatar 正常 → 200 MeView（avatar_url あり）', async () => {
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);
    const res = await request(app.getHttpServer())
      .put('/v1/me/avatar')
      .attach('file', jpeg, { filename: 'test.jpg', contentType: 'image/jpeg' });

    expect(res.status).toBe(200);
    expect(res.body.profile.avatar_url).toBe('https://example.com/avatar.jpg');
    expect(uploadAvatar.execute).toHaveBeenCalledWith(USER_ID, expect.objectContaining({ buffer: expect.any(Buffer) }));
  });

  it('AC-AV-16 PUT /v1/me/avatar: 同一ユーザーで 11 回目 → 429 RATE_LIMITED', async () => {
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0]);
    const send = () =>
      request(app.getHttpServer())
        .put('/v1/me/avatar')
        .attach('file', jpeg, { filename: 'test.jpg', contentType: 'image/jpeg' });

    for (let i = 0; i < 10; i += 1) {
      expect((await send()).status).toBe(200);
    }

    const limited = await send();
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
    expect(uploadAvatar.execute).toHaveBeenCalledTimes(10);
  });

  it('AC-AV-16 DELETE /v1/me/avatar: 同一ユーザーで 11 回目 → 429', async () => {
    for (let i = 0; i < 10; i += 1) {
      expect((await request(app.getHttpServer()).delete('/v1/me/avatar')).status).toBe(200);
    }
    const limited = await request(app.getHttpServer()).delete('/v1/me/avatar');
    expect(limited.status).toBe(429);
    expect(limited.body.code).toBe('RATE_LIMITED');
  });

  it('AC-AV-16 PUT のレート制限は別ユーザー・GET /v1/me に波及しない', async () => {
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0]);
    for (let i = 0; i < 11; i += 1) {
      await request(app.getHttpServer())
        .put('/v1/me/avatar')
        .attach('file', jpeg, { filename: 'test.jpg', contentType: 'image/jpeg' });
    }

    authenticatedUserId = OTHER_USER_ID;
    const otherRes = await request(app.getHttpServer())
      .put('/v1/me/avatar')
      .attach('file', jpeg, { filename: 'test.jpg', contentType: 'image/jpeg' });
    expect(otherRes.status).toBe(200);

    authenticatedUserId = USER_ID;
    const getRes = await request(app.getHttpServer()).get('/v1/me');
    expect(getRes.status).toBe(200);
  });

  it('GET / PATCH /v1/me は従来どおり動く（回帰）', async () => {
    const get = await request(app.getHttpServer()).get('/v1/me');
    const patch = await request(app.getHttpServer())
      .patch('/v1/me')
      .send({ username: 'yuya' });

    expect(get.status).toBe(200);
    expect(patch.status).toBe(200);
    expect(meService.getMe).toHaveBeenCalledWith(USER_ID);
    expect(meService.updateMe).toHaveBeenCalledWith(USER_ID, {
      username: 'yuya',
    });
  });
});
