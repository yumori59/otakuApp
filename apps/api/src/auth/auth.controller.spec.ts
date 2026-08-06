import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { ThrottlerModule } from '@nestjs/throttler';
import request from 'supertest';
import { configureApp } from '../app.setup';
import { IS_PUBLIC_KEY } from '../common/decorators/public.decorator';
import { THROTTLER_CONFIG } from '../common/throttling/throttler-config';
import { AuthController } from './auth.controller';
import { ChangePasswordUseCase } from './use-cases/change-password.use-case';
import { LoginWithEmailUseCase } from './use-cases/login-with-email.use-case';
import { LogoutUseCase } from './use-cases/logout.use-case';
import { RefreshTokenUseCase } from './use-cases/refresh-token.use-case';
import { RegisterWithEmailUseCase } from './use-cases/register-with-email.use-case';
import { RequestPasswordResetUseCase } from './use-cases/request-password-reset.use-case';
import { ResetPasswordUseCase } from './use-cases/reset-password.use-case';
import { SignInWithAppleUseCase } from './use-cases/sign-in-with-apple.use-case';
import { SignInWithGoogleUseCase } from './use-cases/sign-in-with-google.use-case';

const RAW_REFRESH = 'raw-refresh-token';
const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const PASSWORD = 'correct horse battery';

function signInResponse(isNew: boolean) {
  return {
    access_token: 'signed.access.token',
    refresh_token: RAW_REFRESH,
    expires_in: 3600,
    token_type: 'Bearer',
    user: {
      id: USER_ID,
      account_id: 'ACC-3F9A21',
      display_name: null,
      plan: 'free',
      is_new: isNew,
    },
  };
}

describe('AuthController', () => {
  let app: INestApplication;
  let signIn: { execute: jest.Mock };
  let signInGoogle: { execute: jest.Mock };
  let register: { execute: jest.Mock };
  let login: { execute: jest.Mock };
  let changePassword: { execute: jest.Mock };
  let resetRequest: { execute: jest.Mock };
  let resetPassword: { execute: jest.Mock };
  let refresh: { execute: jest.Mock };
  let logout: { execute: jest.Mock };
  /** JwtAuthGuard の代わりに req.user を差し込むためのフラグ。 */
  let authenticatedUserId: string | null;

  beforeEach(async () => {
    signIn = { execute: jest.fn().mockResolvedValue(signInResponse(true)) };
    signInGoogle = {
      execute: jest.fn().mockResolvedValue(signInResponse(true)),
    };
    register = { execute: jest.fn().mockResolvedValue(signInResponse(true)) };
    login = { execute: jest.fn().mockResolvedValue(signInResponse(false)) };
    changePassword = {
      execute: jest.fn().mockResolvedValue({
        access_token: 'signed.access.token',
        refresh_token: 'new-refresh-token',
        expires_in: 3600,
        token_type: 'Bearer',
      }),
    };
    resetRequest = { execute: jest.fn().mockResolvedValue(undefined) };
    resetPassword = {
      execute: jest.fn().mockResolvedValue(signInResponse(false)),
    };
    refresh = {
      execute: jest.fn().mockResolvedValue({
        access_token: 'signed.access.token',
        refresh_token: 'rotated-refresh-token',
        expires_in: 3600,
        token_type: 'Bearer',
      }),
    };
    logout = { execute: jest.fn().mockResolvedValue(undefined) };
    authenticatedUserId = USER_ID;

    const moduleRef = await Test.createTestingModule({
      imports: [ThrottlerModule.forRoot(THROTTLER_CONFIG)],
      controllers: [AuthController],
      providers: [
        { provide: SignInWithAppleUseCase, useValue: signIn },
        { provide: SignInWithGoogleUseCase, useValue: signInGoogle },
        { provide: RegisterWithEmailUseCase, useValue: register },
        { provide: LoginWithEmailUseCase, useValue: login },
        { provide: ChangePasswordUseCase, useValue: changePassword },
        { provide: RequestPasswordResetUseCase, useValue: resetRequest },
        { provide: ResetPasswordUseCase, useValue: resetPassword },
        { provide: RefreshTokenUseCase, useValue: refresh },
        { provide: LogoutUseCase, useValue: logout },
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

  it('3 エンドポイントすべてに @Public() が付いている（BE-4 の意図的公開）', () => {
    const handlers = [
      AuthController.prototype.signInWithApple,
      AuthController.prototype.refresh,
      AuthController.prototype.logout,
    ];
    handlers.forEach((handler) => {
      expect(Reflect.getMetadata(IS_PUBLIC_KEY, handler)).toBe(true);
    });
  });

  it('POST /v1/auth/apple は 200 でトークンとユーザーを返す', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/auth/apple')
      .send({ identity_token: 'apple.identity.token', nonce: 'nonce-abc' });

    expect(res.status).toBe(200);
    expect(res.body.token_type).toBe('Bearer');
    expect(res.body.user.is_new).toBe(true);
    expect(signIn.execute).toHaveBeenCalledWith({
      identity_token: 'apple.identity.token',
      nonce: 'nonce-abc',
    });
  });

  it('POST /v1/auth/apple の identity_token 欠落は VALIDATION_ERROR 400', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/auth/apple')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_ERROR');
    expect(signIn.execute).not.toHaveBeenCalled();
  });

  it('POST /v1/auth/apple の未知キーは VALIDATION_ERROR 400', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/auth/apple')
      .send({ identity_token: 'apple.identity.token', owner_id: 'x' });

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_ERROR');
  });

  it('POST /v1/auth/refresh は 200 で回転後のトークンを返す', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/auth/refresh')
      .send({ refresh_token: RAW_REFRESH });

    expect(res.status).toBe(200);
    expect(res.body.refresh_token).toBe('rotated-refresh-token');
    expect(refresh.execute).toHaveBeenCalledWith({
      refresh_token: RAW_REFRESH,
    });
  });

  it('POST /v1/auth/refresh の refresh_token 欠落は VALIDATION_ERROR 400', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/auth/refresh')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_ERROR');
  });

  it('AC-AUTH-08 POST /v1/auth/logout は該当 refresh を失効させ 204', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/auth/logout')
      .send({ refresh_token: RAW_REFRESH });

    expect(res.status).toBe(204);
    expect(res.body).toEqual({});
    expect(logout.execute).toHaveBeenCalledWith({
      refresh_token: RAW_REFRESH,
    });
  });

  it('AC-AUTH-08 未知・失効済みの refresh でも 204（冪等）', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/auth/logout')
      .send({ refresh_token: 'already-revoked' });

    expect(res.status).toBe(204);
  });

  it('AC-AUTH-08 logout の refresh_token 欠落は VALIDATION_ERROR 400', async () => {
    const res = await request(app.getHttpServer())
      .post('/v1/auth/logout')
      .send({});

    expect(res.status).toBe(400);
    expect(res.body.code).toBe('VALIDATION_ERROR');
    expect(logout.execute).not.toHaveBeenCalled();
  });

  describe('POST /v1/auth/google', () => {
    it('AC-GA-01 200 でトークンとユーザーを返す（キーは apple と同形）', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/google')
        .send({ id_token: 'google.id.token', nonce: 'nonce-abc' });

      expect(res.status).toBe(200);
      expect(Object.keys(res.body).sort()).toEqual([
        'access_token',
        'expires_in',
        'refresh_token',
        'token_type',
        'user',
      ]);
      expect(signInGoogle.execute).toHaveBeenCalledWith({
        id_token: 'google.id.token',
        nonce: 'nonce-abc',
      });
    });

    it('id_token 欠落は VALIDATION_ERROR 400', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/google')
        .send({});

      expect(res.status).toBe(400);
      expect(res.body.code).toBe('VALIDATION_ERROR');
      expect(signInGoogle.execute).not.toHaveBeenCalled();
    });

    it('未知キー（identity_token 誤用）は VALIDATION_ERROR 400', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/google')
        .send({ identity_token: 'google.id.token' });

      expect(res.status).toBe(400);
      expect(res.body.code).toBe('VALIDATION_ERROR');
    });
  });

  describe('POST /v1/auth/register', () => {
    it('AC-EP-01 成功は 201', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/register')
        .send({ email: 'fan@example.com', password: PASSWORD });

      expect(res.status).toBe(201);
      expect(res.body.user.is_new).toBe(true);
      expect(register.execute).toHaveBeenCalledWith({
        email: 'fan@example.com',
        password: PASSWORD,
      });
    });

    it('AC-EP-03 email の前後空白は落として use-case に渡す', async () => {
      await request(app.getHttpServer())
        .post('/v1/auth/register')
        .send({ email: ' Fan@Example.com ', password: PASSWORD });

      expect(register.execute).toHaveBeenCalledWith({
        email: 'Fan@Example.com',
        password: PASSWORD,
      });
    });

    it('AC-EP-06 password 7 文字 / 129 文字は 400', async () => {
      const short = await request(app.getHttpServer())
        .post('/v1/auth/register')
        .send({ email: 'fan@example.com', password: '1234567' });
      const long = await request(app.getHttpServer())
        .post('/v1/auth/register')
        .send({ email: 'fan@example.com', password: 'a'.repeat(129) });

      expect(short.status).toBe(400);
      expect(short.body.code).toBe('VALIDATION_ERROR');
      expect(long.status).toBe(400);
      expect(register.execute).not.toHaveBeenCalled();
    });

    it('AC-EP-06 password 8 文字 / 128 文字ちょうどは通る', async () => {
      const min = await request(app.getHttpServer())
        .post('/v1/auth/register')
        .send({ email: 'fan@example.com', password: '12345678' });
      const max = await request(app.getHttpServer())
        .post('/v1/auth/register')
        .send({ email: 'fan@example.com', password: 'a'.repeat(128) });

      expect(min.status).toBe(201);
      expect(max.status).toBe(201);
    });

    it('AC-EP-06 email 形式不正 / 256 文字は 400', async () => {
      const invalid = await request(app.getHttpServer())
        .post('/v1/auth/register')
        .send({ email: 'not-an-email', password: PASSWORD });
      const tooLong = await request(app.getHttpServer())
        .post('/v1/auth/register')
        .send({
          email: `${'a'.repeat(250)}@example.com`,
          password: PASSWORD,
        });

      expect(invalid.status).toBe(400);
      expect(tooLong.status).toBe(400);
      expect(register.execute).not.toHaveBeenCalled();
    });
  });

  describe('POST /v1/auth/login', () => {
    it('AC-EP-07 成功は 200 で is_new: false', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/login')
        .send({ email: 'fan@example.com', password: PASSWORD });

      expect(res.status).toBe(200);
      expect(res.body.user.is_new).toBe(false);
    });

    it('AC-EP-08 password に下限を掛けない（短くても use-case に渡して 401 にさせる）', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/login')
        .send({ email: 'fan@example.com', password: 'short' });

      expect(res.status).toBe(200);
      expect(login.execute).toHaveBeenCalledWith({
        email: 'fan@example.com',
        password: 'short',
      });
    });

    it('AC-EP-15 同一 email で上限を超えると RATE_LIMITED 429', async () => {
      const send = () =>
        request(app.getHttpServer())
          .post('/v1/auth/login')
          .send({ email: 'fan@example.com', password: PASSWORD });

      for (let i = 0; i < 10; i += 1) {
        expect((await send()).status).toBe(200);
      }

      const limited = await send();
      expect(limited.status).toBe(429);
      expect(limited.body.code).toBe('RATE_LIMITED');
      expect(limited.body.request_id).toEqual(expect.any(String));
    });

    it('AC-EP-15 email が違えばカウントは共有されない', async () => {
      for (let i = 0; i < 10; i += 1) {
        await request(app.getHttpServer())
          .post('/v1/auth/login')
          .send({ email: 'fan@example.com', password: PASSWORD });
      }

      const other = await request(app.getHttpServer())
        .post('/v1/auth/login')
        .send({ email: 'other@example.com', password: PASSWORD });

      expect(other.status).toBe(200);
    });
  });

  describe('POST /v1/auth/password', () => {
    it('AC-EP-13 @Public() が付いていない（Bearer 必須・BE-4）', () => {
      expect(
        Reflect.getMetadata(
          IS_PUBLIC_KEY,
          AuthController.prototype.changePassword,
        ),
      ).toBeUndefined();
    });

    it('AC-EP-11 成功は 200 で TokenPairResponse（user ブロックを含まない）', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/password')
        .send({ current_password: PASSWORD, new_password: 'a brand new one' });

      expect(res.status).toBe(200);
      expect(Object.keys(res.body).sort()).toEqual([
        'access_token',
        'expires_in',
        'refresh_token',
        'token_type',
      ]);
      expect(changePassword.execute).toHaveBeenCalledWith(USER_ID, {
        current_password: PASSWORD,
        new_password: 'a brand new one',
      });
    });

    it('AC-EP-13 認証されていなければ UNAUTHENTICATED 401 で use-case を呼ばない', async () => {
      authenticatedUserId = null;

      const res = await request(app.getHttpServer())
        .post('/v1/auth/password')
        .send({ current_password: PASSWORD, new_password: 'a brand new one' });

      expect(res.status).toBe(401);
      expect(res.body.code).toBe('UNAUTHENTICATED');
      expect(changePassword.execute).not.toHaveBeenCalled();
    });

    it('AC-EP-12 new_password が 8 文字未満は 400', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/password')
        .send({ current_password: PASSWORD, new_password: 'short' });

      expect(res.status).toBe(400);
      expect(res.body.code).toBe('VALIDATION_ERROR');
      expect(changePassword.execute).not.toHaveBeenCalled();
    });
  });

  describe('POST /v1/auth/password/reset-request', () => {
    it('AC-PR-01 202 でボディが空', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/password/reset-request')
        .send({ email: 'fan@example.com' });

      expect(res.status).toBe(202);
      expect(res.body).toEqual({});
      expect(res.text).toBe('');
      expect(resetRequest.execute).toHaveBeenCalledWith({
        email: 'fan@example.com',
      });
    });

    it('AC-PR-11 email 形式不正は 400', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/password/reset-request')
        .send({ email: 'not-an-email' });

      expect(res.status).toBe(400);
      expect(res.body.code).toBe('VALIDATION_ERROR');
      expect(resetRequest.execute).not.toHaveBeenCalled();
    });

    it('AC-PR-12 3 回を超えると RATE_LIMITED 429', async () => {
      const send = () =>
        request(app.getHttpServer())
          .post('/v1/auth/password/reset-request')
          .send({ email: 'fan@example.com' });

      for (let i = 0; i < 3; i += 1) {
        expect((await send()).status).toBe(202);
      }

      const limited = await send();
      expect(limited.status).toBe(429);
      expect(limited.body.code).toBe('RATE_LIMITED');
    });
  });

  describe('POST /v1/auth/password/reset', () => {
    it('AC-PR-07 成功は 200 で login と同形', async () => {
      const res = await request(app.getHttpServer())
        .post('/v1/auth/password/reset')
        .send({
          email: 'fan@example.com',
          code: '04821093',
          new_password: 'a brand new one',
        });

      expect(res.status).toBe(200);
      expect(res.body.user.is_new).toBe(false);
      expect(resetPassword.execute).toHaveBeenCalledWith({
        email: 'fan@example.com',
        code: '04821093',
        new_password: 'a brand new one',
      });
    });

    it('AC-PR-11 code が 8 桁数字でなければ 400', async () => {
      for (const code of ['1234567', '123456789', '0482109a', '']) {
        const res = await request(app.getHttpServer())
          .post('/v1/auth/password/reset')
          .send({
            email: 'fan@example.com',
            code,
            new_password: 'a brand new one',
          });

        expect(res.status).toBe(400);
        expect(res.body.code).toBe('VALIDATION_ERROR');
      }
      expect(resetPassword.execute).not.toHaveBeenCalled();
    });

    it('AC-PR-11 new_password の制約は register と同一（8〜128）', async () => {
      const short = await request(app.getHttpServer())
        .post('/v1/auth/password/reset')
        .send({
          email: 'fan@example.com',
          code: '04821093',
          new_password: 'short',
        });

      expect(short.status).toBe(400);
    });

    it('AC-PR-12 10 回を超えると RATE_LIMITED 429', async () => {
      const send = () =>
        request(app.getHttpServer())
          .post('/v1/auth/password/reset')
          .send({
            email: 'fan@example.com',
            code: '04821093',
            new_password: 'a brand new one',
          });

      for (let i = 0; i < 10; i += 1) {
        expect((await send()).status).toBe(200);
      }

      const limited = await send();
      expect(limited.status).toBe(429);
      expect(limited.body.code).toBe('RATE_LIMITED');
    });

    it('reset と reset-request と password のルートが衝突しない', async () => {
      const password = await request(app.getHttpServer())
        .post('/v1/auth/password')
        .send({ current_password: PASSWORD, new_password: 'a brand new one' });

      expect(password.status).toBe(200);
      expect(resetPassword.execute).not.toHaveBeenCalled();
      expect(resetRequest.execute).not.toHaveBeenCalled();
      expect(changePassword.execute).toHaveBeenCalledTimes(1);
    });
  });

  it('公開すべき 8 ルートに @Public() が付いている（BE-4 の意図的公開）', () => {
    const handlers = [
      AuthController.prototype.signInWithApple,
      AuthController.prototype.signInWithGoogle,
      AuthController.prototype.register,
      AuthController.prototype.login,
      AuthController.prototype.requestPasswordReset,
      AuthController.prototype.resetPassword,
      AuthController.prototype.refresh,
      AuthController.prototype.logout,
    ];
    handlers.forEach((handler) => {
      expect(Reflect.getMetadata(IS_PUBLIC_KEY, handler)).toBe(true);
    });
  });
});
