import { HttpException } from '@nestjs/common';
import { ERROR_CODE_STATUS, ErrorCode } from './error-codes';

export type ErrorDetails = Record<string, unknown>;

/**
 * 契約 envelope ({code, message, details, request_id}) に載せる例外。
 * status を省略すると ERROR_CODE_STATUS の既定値を使う。
 */
export class AppError extends HttpException {
  readonly code: ErrorCode;
  readonly details: ErrorDetails | null;

  constructor(
    code: ErrorCode,
    message?: string,
    details?: ErrorDetails | null,
    status?: number,
  ) {
    const resolvedMessage = message ?? code;
    const resolvedDetails = details ?? null;
    super(
      { code, message: resolvedMessage, details: resolvedDetails },
      status ?? ERROR_CODE_STATUS[code],
    );
    this.code = code;
    this.details = resolvedDetails;
  }

  static validation(message: string, details?: ErrorDetails): AppError {
    return new AppError(ErrorCode.VALIDATION_ERROR, message, details);
  }

  static unauthenticated(message = 'authentication required'): AppError {
    return new AppError(ErrorCode.UNAUTHENTICATED, message);
  }

  static notFound(message = 'resource not found'): AppError {
    return new AppError(ErrorCode.NOT_FOUND, message);
  }

  static conflict(message: string, details?: ErrorDetails): AppError {
    return new AppError(ErrorCode.CONFLICT, message, details);
  }
}
