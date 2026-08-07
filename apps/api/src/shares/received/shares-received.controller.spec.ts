import 'reflect-metadata';
import { INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { APP_GUARD } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { ThrottlerStorage } from '@nestjs/throttler';
import { configureApp } from '../../app.setup';
import { IS_PUBLIC_KEY } from '../../common/decorators/public.decorator';
import { JwtAuthGuard } from '../../common/guards/jwt-auth.guard';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { SharesReceivedController } from './shares-received.controller';
import { GetBoardUseCase } from './use-cases/get-board.use-case';
import { ListInboxUseCase } from './use-cases/list-inbox.use-case';
import { RedeemShareUseCase } from './use-cases/redeem-share.use-case';
import { SetHiddenUseCase } from './use-cases/set-hidden.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';

describe('SharesReceivedController', () => {
  let app: INestApplication;
  let listInbox: { execute: jest.Mock };
  let getBoard: { execute: jest.Mock };
  let redeemShare: { execute: jest.Mock };
  let setHidden: { execute: jest.Mock };

  async function buildApp(): Promise<INestApplication> {
    const moduleRef = await Test.createTestingModule({
      controllers: [SharesReceivedController],
      providers: [
        { provide: ListInboxUseCase, useValue: listInbox },
        { provide: GetBoardUseCase, useValue: getBoard },
        { provide: RedeemShareUseCase, useValue: redeemShare },
        { provide: SetHiddenUseCase, useValue: setHidden },
        {
          provide: ThrottlerStorage,
          useValue: {
            increment: jest.fn().mockResolvedValue({
              totalHits: 1,
              timeToExpire: 60,
              isBlocked: false,
              timeToBlockExpire: 0,
            }),
          },
        },
        {
          provide: JwtService,
          useValue: {
            verifyAsync: jest.fn().mockResolvedValue({ sub: USER_ID }),
          },
        },
        { provide: ConfigService, useValue: { get: jest.fn(() => 'secret') } },
        { provide: APP_GUARD, useClass: JwtAuthGuard },
      ],
    }).compile();

    const built = configureApp(moduleRef.createNestApplication());
    await built.init();
    return built;
  }

  beforeEach(async () => {
    listInbox = { execute: jest.fn().mockResolvedValue([]) };
    getBoard = { execute: jest.fn().mockResolvedValue({ share_id: SHARE_ID }) };
    redeemShare = {
      execute: jest.fn().mockResolvedValue({ share_id: SHARE_ID }),
    };
    setHidden = { execute: jest.fn().mockResolvedValue(undefined) };
    app = await buildApp();
  });

  afterEach(async () => {
    await app?.close();
  });

  it('どのハンドラにも @Public() を付けない（全て認証必須 — BE-4）', () => {
    const handlers = [
      SharesReceivedController.prototype.list,
      SharesReceivedController.prototype.get,
      SharesReceivedController.prototype.redeem,
      SharesReceivedController.prototype.hide,
      SharesReceivedController.prototype.unhide,
    ];
    handlers.forEach((handler) => {
      expect(Reflect.getMetadata(IS_PUBLIC_KEY, handler)).toBeUndefined();
    });
    expect(
      Reflect.getMetadata(IS_PUBLIC_KEY, SharesReceivedController),
    ).toBeUndefined();
  });

  it('Bearer 無しは全ルートで 401（Guard 漏れ検出 — BE-4）', async () => {
    const server = app.getHttpServer();
    const list = await request(server).get('/v1/shares/received');
    const get = await request(server).get(`/v1/shares/received/${SHARE_ID}`);
    const redeem = await request(server)
      .post('/v1/shares/received/redeem')
      .send({ token: 'x' });
    const hide = await request(server).post(
      `/v1/shares/received/${SHARE_ID}/hide`,
    );
    const unhide = await request(server).delete(
      `/v1/shares/received/${SHARE_ID}/hide`,
    );

    const results = [list, get, redeem, hide, unhide];
    results.forEach((res) => expect(res.status).toBe(401));
    expect(listInbox.execute).not.toHaveBeenCalled();
    expect(getBoard.execute).not.toHaveBeenCalled();
    expect(redeemShare.execute).not.toHaveBeenCalled();
    expect(setHidden.execute).not.toHaveBeenCalled();
  });

  it('認証済み GET /v1/shares/received は { items } を返す', async () => {
    const res = await request(app.getHttpServer())
      .get('/v1/shares/received')
      .set('Authorization', 'Bearer valid.access.token');

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ items: [] });
    expect(listInbox.execute).toHaveBeenCalledWith(USER_ID);
  });

  it('認証済み GET /v1/shares/received/:id は use case の戻り値をそのまま返す', async () => {
    const res = await request(app.getHttpServer())
      .get(`/v1/shares/received/${SHARE_ID}`)
      .set('Authorization', 'Bearer valid.access.token');

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ share_id: SHARE_ID });
    expect(getBoard.execute).toHaveBeenCalledWith(USER_ID, SHARE_ID);
  });

  it('招待されていない :id への GET は 404 SHARE_INVALID を envelope で返す', async () => {
    getBoard.execute.mockRejectedValue(
      new AppError(ErrorCode.SHARE_INVALID, 'share link is invalid'),
    );

    const res = await request(app.getHttpServer())
      .get(`/v1/shares/received/${SHARE_ID}`)
      .set('Authorization', 'Bearer valid.access.token');

    expect(res.status).toBe(404);
    expect(res.body.code).toBe('SHARE_INVALID');
  });

  it('POST /v1/shares/received/redeem は 200 { share_id }', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/shares/received/redeem')
      .set('Authorization', 'Bearer valid.access.token')
      .send({ token: 'raw-token' });

    expect(res.status).toBe(200);
    expect(res.body).toEqual({ share_id: SHARE_ID });
    expect(redeemShare.execute).toHaveBeenCalledWith(USER_ID, 'raw-token');
  });

  it('招待されていない redeem は 403 SHARE_NOT_INVITED', async () => {
    redeemShare.execute.mockRejectedValue(
      new AppError(ErrorCode.SHARE_NOT_INVITED, 'not invited'),
    );

    const res = await request(app.getHttpServer())
      .post('/v1/shares/received/redeem')
      .set('Authorization', 'Bearer valid.access.token')
      .send({ token: 'raw-token' });

    expect(res.status).toBe(403);
    expect(res.body.code).toBe('SHARE_NOT_INVITED');
  });

  it('POST /v1/shares/received/:id/hide は 204 で hidden:true を渡す', async () => {
    const res = await request(app.getHttpServer())
      .post(`/v1/shares/received/${SHARE_ID}/hide`)
      .set('Authorization', 'Bearer valid.access.token');

    expect(res.status).toBe(204);
    expect(setHidden.execute).toHaveBeenCalledWith(USER_ID, SHARE_ID, true);
  });

  it('DELETE /v1/shares/received/:id/hide は 204 で hidden:false を渡す', async () => {
    const res = await request(app.getHttpServer())
      .delete(`/v1/shares/received/${SHARE_ID}/hide`)
      .set('Authorization', 'Bearer valid.access.token');

    expect(res.status).toBe(204);
    expect(setHidden.execute).toHaveBeenCalledWith(USER_ID, SHARE_ID, false);
  });
});
