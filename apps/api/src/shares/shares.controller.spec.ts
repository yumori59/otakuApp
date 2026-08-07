import 'reflect-metadata';
import { INestApplication, RequestMethod } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { METHOD_METADATA, PATH_METADATA } from '@nestjs/common/constants';
import { APP_GUARD } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { Test } from '@nestjs/testing';
import { ThrottlerModule } from '@nestjs/throttler';
import request from 'supertest';
import { configureApp } from '../app.setup';
import { IS_PUBLIC_KEY } from '../common/decorators/public.decorator';
import { JwtAuthGuard } from '../common/guards/jwt-auth.guard';
import { THROTTLER_CONFIG } from '../common/throttling/throttler-config';
import { SharesController } from './shares.controller';
import { SharesService } from './shares.service';
import { AddRecipientsUseCase } from './use-cases/add-recipients.use-case';
import { CreateShareUseCase } from './use-cases/create-share.use-case';
import { RemoveRecipientUseCase } from './use-cases/remove-recipient.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';

describe('SharesController', () => {
  let app: INestApplication;
  let createShare: { execute: jest.Mock };
  let addRecipients: { execute: jest.Mock };
  let removeRecipient: { execute: jest.Mock };
  let shares: { list: jest.Mock; revoke: jest.Mock };

  function buildProviders() {
    return [
      { provide: CreateShareUseCase, useValue: createShare },
      { provide: AddRecipientsUseCase, useValue: addRecipients },
      { provide: RemoveRecipientUseCase, useValue: removeRecipient },
      { provide: SharesService, useValue: shares },
      { provide: JwtService, useValue: { verifyAsync: jest.fn() } },
      { provide: ConfigService, useValue: { get: jest.fn() } },
      { provide: APP_GUARD, useClass: JwtAuthGuard },
    ];
  }

  beforeEach(async () => {
    createShare = { execute: jest.fn().mockResolvedValue({ id: SHARE_ID }) };
    addRecipients = {
      execute: jest.fn().mockResolvedValue({ recipients: [] }),
    };
    removeRecipient = { execute: jest.fn().mockResolvedValue(undefined) };
    shares = {
      list: jest.fn().mockResolvedValue([]),
      revoke: jest.fn().mockResolvedValue(undefined),
    };

    const moduleRef = await Test.createTestingModule({
      imports: [ThrottlerModule.forRoot(THROTTLER_CONFIG)],
      controllers: [SharesController],
      providers: buildProviders(),
    }).compile();

    app = configureApp(moduleRef.createNestApplication());
    await app.init();
  });

  afterEach(async () => {
    await app?.close();
  });

  it('どのハンドラにも @Public() を付けない（全て認証必須 — BE-4）', () => {
    const handlers = [
      SharesController.prototype.create,
      SharesController.prototype.list,
      SharesController.prototype.remove,
      SharesController.prototype.addRecipientsToShare,
      SharesController.prototype.removeRecipientFromShare,
    ];
    handlers.forEach((handler) => {
      expect(Reflect.getMetadata(IS_PUBLIC_KEY, handler)).toBeUndefined();
    });
    expect(
      Reflect.getMetadata(IS_PUBLIC_KEY, SharesController),
    ).toBeUndefined();
  });

  it('POST / GET / DELETE :id / POST :id/recipients / DELETE :id/recipients/:account_id を /v1/shares に提供する', () => {
    expect(Reflect.getMetadata(PATH_METADATA, SharesController)).toBe('shares');
    const proto = SharesController.prototype as unknown as Record<
      string,
      unknown
    >;
    const routes = Object.getOwnPropertyNames(proto)
      .filter((name) => name !== 'constructor')
      .map((name) => ({
        method: Reflect.getMetadata(METHOD_METADATA, proto[name] as object) as
          number | undefined,
        path: String(Reflect.getMetadata(PATH_METADATA, proto[name] as object)),
      }))
      .filter((route) => route.method !== undefined)
      .map((route) => `${route.method}:${route.path}`);

    expect(routes.sort()).toEqual(
      [
        `${RequestMethod.POST}:/`,
        `${RequestMethod.GET}:/`,
        `${RequestMethod.DELETE}::id`,
        `${RequestMethod.POST}::id/recipients`,
        `${RequestMethod.DELETE}::id/recipients/:account_id`,
      ].sort(),
    );
  });

  it('Bearer 無しの POST /v1/shares は UNAUTHENTICATED 401（Guard 漏れ検出 — BE-4）', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/shares')
      .send({ scope_type: 'tour', scope_id: TOUR_ID });

    expect(res.status).toBe(401);
    expect(res.body.code).toBe('UNAUTHENTICATED');
    expect(createShare.execute).not.toHaveBeenCalled();
  });

  it('Bearer 無しの GET /v1/shares / DELETE /v1/shares/:id / recipients も 401', async () => {
    const list = await request(app.getHttpServer()).get('/v1/shares');
    const remove = await request(app.getHttpServer()).delete(
      `/v1/shares/${SHARE_ID}`,
    );
    const addRes = await request(app.getHttpServer())
      .post(`/v1/shares/${SHARE_ID}/recipients`)
      .send({ account_ids: ['ACC-1A2B3C'] });
    const removeRes = await request(app.getHttpServer()).delete(
      `/v1/shares/${SHARE_ID}/recipients/ACC-1A2B3C`,
    );

    expect(list.status).toBe(401);
    expect(remove.status).toBe(401);
    expect(addRes.status).toBe(401);
    expect(removeRes.status).toBe(401);
    expect(shares.list).not.toHaveBeenCalled();
    expect(shares.revoke).not.toHaveBeenCalled();
    expect(addRecipients.execute).not.toHaveBeenCalled();
    expect(removeRecipient.execute).not.toHaveBeenCalled();
  });

  async function authedApp(): Promise<INestApplication> {
    const moduleRef = await Test.createTestingModule({
      imports: [ThrottlerModule.forRoot(THROTTLER_CONFIG)],
      controllers: [SharesController],
      providers: [
        ...buildProviders(),
        {
          provide: JwtService,
          useValue: {
            verifyAsync: jest.fn().mockResolvedValue({ sub: USER_ID }),
          },
        },
        { provide: ConfigService, useValue: { get: jest.fn(() => 'secret') } },
      ],
    }).compile();

    const built = configureApp(moduleRef.createNestApplication());
    await built.init();
    return built;
  }

  it('認証済みなら GET /v1/shares は { items } を返す', async () => {
    const app2 = await authedApp();
    try {
      const res = await request(app2.getHttpServer())
        .get('/v1/shares')
        .set('Authorization', 'Bearer valid.access.token');

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ items: [] });
      expect(shares.list).toHaveBeenCalledWith(USER_ID);
    } finally {
      await app2.close();
    }
  });

  it('認証済みの DELETE /v1/shares/:id は 204 で revoke を呼ぶ', async () => {
    const app2 = await authedApp();
    try {
      const res = await request(app2.getHttpServer())
        .delete(`/v1/shares/${SHARE_ID}`)
        .set('Authorization', 'Bearer valid.access.token');

      expect(res.status).toBe(204);
      expect(shares.revoke).toHaveBeenCalledWith(USER_ID, SHARE_ID);
    } finally {
      await app2.close();
    }
  });

  it('認証済みの POST /v1/shares/:id/recipients は 200 で { recipients } を返す', async () => {
    const app2 = await authedApp();
    try {
      const res = await request(app2.getHttpServer())
        .post(`/v1/shares/${SHARE_ID}/recipients`)
        .set('Authorization', 'Bearer valid.access.token')
        .send({ account_ids: ['ACC-1A2B3C'] });

      expect(res.status).toBe(200);
      expect(res.body).toEqual({ recipients: [] });
      expect(addRecipients.execute).toHaveBeenCalledWith(
        USER_ID,
        SHARE_ID,
        expect.objectContaining({ account_ids: ['ACC-1A2B3C'] }),
      );
    } finally {
      await app2.close();
    }
  });

  it('認証済みの DELETE /v1/shares/:id/recipients/:account_id は 204', async () => {
    const app2 = await authedApp();
    try {
      const res = await request(app2.getHttpServer())
        .delete(`/v1/shares/${SHARE_ID}/recipients/ACC-1A2B3C`)
        .set('Authorization', 'Bearer valid.access.token');

      expect(res.status).toBe(204);
      expect(removeRecipient.execute).toHaveBeenCalledWith(
        USER_ID,
        SHARE_ID,
        'ACC-1A2B3C',
      );
    } finally {
      await app2.close();
    }
  });
});
