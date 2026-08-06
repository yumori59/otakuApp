import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  Logger,
} from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { AppError, ErrorDetails } from '../errors/app-error';
import {
  ERROR_CODE_STATUS,
  ErrorCode,
  errorCodeFromStatus,
} from '../errors/error-codes';
import { REQUEST_ID_HEADER } from '../interceptors/request-id.interceptor';

interface ErrorEnvelope {
  code: ErrorCode;
  message: string;
  details: ErrorDetails | null;
  request_id: string;
}

interface MinimalRequest {
  headers?: Record<string, string | string[] | undefined>;
  method?: string;
  url?: string;
  requestId?: string;
}

interface MinimalResponse {
  status(code: number): { json(body: unknown): unknown };
  setHeader(name: string, value: string): unknown;
}

/**
 * Prisma の既知エラーを契約コードへ写す (BE-6)。
 * ここに無いコードは INTERNAL 500 のまま（黙って別扱いにしない）。
 * メッセージは Prisma のものを使わない（テーブル名・カラム名を漏らさない）。
 */
const PRISMA_ERROR_MAP: Record<string, { code: ErrorCode; message: string }> = {
  P2002: { code: ErrorCode.CONFLICT, message: 'resource already exists' },
  P2025: { code: ErrorCode.NOT_FOUND, message: 'resource not found' },
};

function headerValue(
  headers: MinimalRequest['headers'],
  name: string,
): string | undefined {
  const raw = headers?.[name];
  return Array.isArray(raw) ? raw[0] : raw;
}

/**
 * 全例外を契約 envelope に正規化する。
 * 未知例外はスタックをログにだけ出し、レスポンスには INTERNAL のみを返す。
 */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger(AllExceptionsFilter.name);

  catch(exception: unknown, host: ArgumentsHost): void {
    const http = host.switchToHttp();
    const req = http.getRequest<MinimalRequest>();
    const res = http.getResponse<MinimalResponse>();

    const requestId =
      req?.requestId ??
      headerValue(req?.headers, REQUEST_ID_HEADER.toLowerCase()) ??
      randomUUID();

    const { status, envelope } = this.normalize(exception, requestId);

    if (status >= HttpStatus.INTERNAL_SERVER_ERROR) {
      this.logger.error(
        `${req?.method ?? '-'} ${req?.url ?? '-'} request_id=${requestId}`,
        exception instanceof Error ? exception.stack : String(exception),
      );
    }

    res.setHeader(REQUEST_ID_HEADER, requestId);
    res.status(status).json(envelope);
  }

  private normalize(
    exception: unknown,
    requestId: string,
  ): { status: number; envelope: ErrorEnvelope } {
    if (exception instanceof AppError) {
      return {
        status: exception.getStatus(),
        envelope: {
          code: exception.code,
          message: exception.message,
          details: exception.details,
          request_id: requestId,
        },
      };
    }

    if (exception instanceof HttpException) {
      const status = exception.getStatus();
      const body = exception.getResponse();
      return {
        status,
        envelope: {
          code: errorCodeFromStatus(status),
          message: extractMessage(body, exception.message),
          details: extractDetails(body),
          request_id: requestId,
        },
      };
    }

    if (exception instanceof Prisma.PrismaClientKnownRequestError) {
      const mapped = PRISMA_ERROR_MAP[exception.code];
      if (mapped) {
        return {
          status: ERROR_CODE_STATUS[mapped.code],
          envelope: {
            code: mapped.code,
            message: mapped.message,
            details: null,
            request_id: requestId,
          },
        };
      }
    }

    return {
      status: HttpStatus.INTERNAL_SERVER_ERROR,
      envelope: {
        code: ErrorCode.INTERNAL,
        message: 'internal server error',
        details: null,
        request_id: requestId,
      },
    };
  }
}

function extractMessage(body: unknown, fallback: string): string {
  if (typeof body === 'string') return body;
  if (body && typeof body === 'object') {
    const message = (body as { message?: unknown }).message;
    if (typeof message === 'string') return message;
    if (Array.isArray(message) && typeof message[0] === 'string') {
      return message[0];
    }
  }
  return fallback;
}

function extractDetails(body: unknown): ErrorDetails | null {
  if (body && typeof body === 'object') {
    const message = (body as { message?: unknown }).message;
    if (Array.isArray(message)) {
      return { messages: message.map((m) => String(m)) };
    }
    const details = (body as { details?: unknown }).details;
    if (details && typeof details === 'object') {
      return details as ErrorDetails;
    }
  }
  return null;
}
