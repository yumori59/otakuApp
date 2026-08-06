import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtAuthGuard } from './jwt-auth.guard';
import { AppError } from '../errors/app-error';

interface CtxParts {
  ctx: ExecutionContext;
  req: { headers: Record<string, string>; user?: { id: string } };
}

function createCtx(headers: Record<string, string> = {}): CtxParts {
  const req: CtxParts['req'] = { headers };
  const ctx = {
    getHandler: () => function handler() {},
    getClass: () => class Controller {},
    switchToHttp: () => ({ getRequest: () => req }),
  } as unknown as ExecutionContext;
  return { ctx, req };
}

describe('JwtAuthGuard', () => {
  let reflector: { getAllAndOverride: jest.Mock };
  let jwt: { verifyAsync: jest.Mock };
  let config: { get: jest.Mock };
  let guard: JwtAuthGuard;

  beforeEach(() => {
    reflector = { getAllAndOverride: jest.fn().mockReturnValue(false) };
    jwt = { verifyAsync: jest.fn() };
    config = { get: jest.fn().mockReturnValue('test-secret') };
    guard = new JwtAuthGuard(
      reflector as unknown as Reflector,
      jwt as never,
      config as never,
    );
  });

  it('AC-CORE-03 Bearer が無ければ UNAUTHENTICATED 401 を投げる', async () => {
    const { ctx } = createCtx();

    await expect(guard.canActivate(ctx)).rejects.toMatchObject({
      code: 'UNAUTHENTICATED',
    });
    await expect(guard.canActivate(ctx)).rejects.toBeInstanceOf(AppError);

    try {
      await guard.canActivate(ctx);
      fail('should throw');
    } catch (e) {
      expect((e as AppError).getStatus()).toBe(401);
    }
  });

  it('AC-CORE-03 Authorization スキームが Bearer 以外なら 401', async () => {
    const { ctx } = createCtx({ authorization: 'Basic abcdef' });

    await expect(guard.canActivate(ctx)).rejects.toMatchObject({
      code: 'UNAUTHENTICATED',
    });
    expect(jwt.verifyAsync).not.toHaveBeenCalled();
  });

  it('AC-CORE-04 @Public() 付きハンドラはトークン無しで通過する', async () => {
    reflector.getAllAndOverride.mockReturnValue(true);
    const { ctx } = createCtx();

    await expect(guard.canActivate(ctx)).resolves.toBe(true);
    expect(jwt.verifyAsync).not.toHaveBeenCalled();
  });

  it('AC-CORE-05 不正な access token は UNAUTHENTICATED 401', async () => {
    jwt.verifyAsync.mockRejectedValue(new Error('invalid signature'));
    const { ctx } = createCtx({ authorization: 'Bearer broken.token.here' });

    await expect(guard.canActivate(ctx)).rejects.toMatchObject({
      code: 'UNAUTHENTICATED',
    });
  });

  it('AC-CORE-05 sub を持たない payload は UNAUTHENTICATED 401', async () => {
    jwt.verifyAsync.mockResolvedValue({ foo: 'bar' });
    const { ctx } = createCtx({ authorization: 'Bearer no.sub.token' });

    await expect(guard.canActivate(ctx)).rejects.toMatchObject({
      code: 'UNAUTHENTICATED',
    });
  });

  it('AC-CORE-05 有効な token は通過し req.user.id に sub を設定する', async () => {
    jwt.verifyAsync.mockResolvedValue({
      sub: '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f',
    });
    const { ctx, req } = createCtx({ authorization: 'Bearer good.token' });

    await expect(guard.canActivate(ctx)).resolves.toBe(true);
    expect(req.user).toEqual({ id: '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f' });
    expect(jwt.verifyAsync).toHaveBeenCalledWith('good.token', {
      secret: 'test-secret',
    });
  });
});
