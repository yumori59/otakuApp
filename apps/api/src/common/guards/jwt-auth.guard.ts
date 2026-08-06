import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { AppError } from '../errors/app-error';
import { IS_PUBLIC_KEY } from '../decorators/public.decorator';
import { AuthenticatedUser } from '../decorators/current-user.decorator';

interface RequestWithUser {
  headers?: Record<string, string | string[] | undefined>;
  user?: AuthenticatedUser;
}

/**
 * APP_GUARD として全ルートに適用する。`@Public()` 付きのみ素通し。
 * 検証済み JWT の sub を req.user.id に載せる（BE-4 の ownerId スコープの起点）。
 */
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly jwt: JwtService,
    private readonly config: ConfigService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;

    const req = context.switchToHttp().getRequest<RequestWithUser>();
    const token = extractBearerToken(req?.headers?.authorization);
    if (!token) {
      throw AppError.unauthenticated('missing bearer token');
    }

    let payload: { sub?: unknown };
    try {
      payload = await this.jwt.verifyAsync<{ sub?: unknown }>(token, {
        secret: this.config.get<string>('JWT_ACCESS_SECRET'),
      });
    } catch {
      throw AppError.unauthenticated('invalid access token');
    }

    if (typeof payload?.sub !== 'string' || payload.sub.length === 0) {
      throw AppError.unauthenticated('invalid access token');
    }

    req.user = { id: payload.sub };
    return true;
  }
}

function extractBearerToken(
  authorization: string | string[] | undefined,
): string | null {
  const raw = Array.isArray(authorization) ? authorization[0] : authorization;
  if (typeof raw !== 'string') return null;
  const [scheme, token] = raw.split(' ');
  if (scheme?.toLowerCase() !== 'bearer' || !token) return null;
  return token;
}
