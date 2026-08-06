import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { ThrottlerModule } from '@nestjs/throttler';
import request from 'supertest';
import { configureApp } from '../app.setup';
import { IS_PUBLIC_KEY } from '../common/decorators/public.decorator';
import { THROTTLER_CONFIG } from '../common/throttling/throttler-config';
import { MeController } from './me.controller';
import { MeService } from './me.service';
import { DeleteMeUseCase } from './use-cases/delete-me.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000002';
const PASSWORD = 'correct horse battery';

describe('MeController', () => {
  let app: INestApplication;
  let meService: { getMe: jest.Mock; updateMe: jest.Mock };
  let deleteMe: { execute: jest.Mock };
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
    authenticatedUserId = USER_ID;

    const moduleRef = await Test.createTestingModule({
      imports: [ThrottlerModule.forRoot(THROTTLER_CONFIG)],
      controllers: [MeController],
      providers: [
        { provide: MeService, useValue: meService },
        { provide: DeleteMeUseCase, useValue: deleteMe },
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
