import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { Observable } from 'rxjs';

export const REQUEST_ID_HEADER = 'X-Request-Id';

interface RequestWithId {
  headers?: Record<string, string | string[] | undefined>;
  requestId?: string;
}

/**
 * `X-Request-Id` を受理（無ければ生成）し、req.requestId とレスポンスヘッダに載せる。
 * AllExceptionsFilter は req.requestId を envelope の request_id に使う。
 */
@Injectable()
export class RequestIdInterceptor implements NestInterceptor {
  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const http = context.switchToHttp();
    const req = http.getRequest<RequestWithId>();
    const res = http.getResponse<{
      setHeader(name: string, value: string): unknown;
    }>();

    const incoming = req?.headers?.[REQUEST_ID_HEADER.toLowerCase()];
    const requestId =
      (Array.isArray(incoming) ? incoming[0] : incoming) ?? randomUUID();

    if (req) req.requestId = requestId;
    res?.setHeader?.(REQUEST_ID_HEADER, requestId);

    return next.handle();
  }
}
