import { HttpStatus } from '@nestjs/common';

/**
 * API 契約 (docs/plans/backend-domain-modules/api-contract.md §0) のエラーコード。
 * ここに無いコードを勝手に増やさない。増やすときは契約側も更新する。
 */
export const ErrorCode = {
  VALIDATION_ERROR: 'VALIDATION_ERROR',
  UNAUTHENTICATED: 'UNAUTHENTICATED',
  AUTH_APPLE_INVALID: 'AUTH_APPLE_INVALID',
  AUTH_REFRESH_INVALID: 'AUTH_REFRESH_INVALID',
  FORBIDDEN: 'FORBIDDEN',
  PLAN_LIMIT_IDENTITY: 'PLAN_LIMIT_IDENTITY',
  PLAN_LIMIT_SHARE: 'PLAN_LIMIT_SHARE',
  NOT_FOUND: 'NOT_FOUND',
  SHARE_INVALID: 'SHARE_INVALID',
  CONFLICT: 'CONFLICT',
  INTERNAL: 'INTERNAL',
  // backend-auth-and-shares-extension で追加 (api-contract-delta.md §0)
  AUTH_GOOGLE_INVALID: 'AUTH_GOOGLE_INVALID',
  AUTH_CREDENTIALS_INVALID: 'AUTH_CREDENTIALS_INVALID',
  AUTH_RESET_CODE_INVALID: 'AUTH_RESET_CODE_INVALID',
  EMAIL_ALREADY_REGISTERED: 'EMAIL_ALREADY_REGISTERED',
  PLAN_LIMIT_SHARE_WRITE: 'PLAN_LIMIT_SHARE_WRITE',
  RATE_LIMITED: 'RATE_LIMITED',
  // share-account-invites で追加 (api-contract-delta.md §0.1)
  /** 招待されていないアカウントからの redeem。**POST /v1/shares/received/redeem 専用**。 */
  SHARE_NOT_INVITED: 'SHARE_NOT_INVITED',
  /** 招待先 ACC-XXXXXX が存在しない。details.unknown_account_ids を付ける。 */
  SHARE_RECIPIENT_UNKNOWN: 'SHARE_RECIPIENT_UNKNOWN',
  /** 自分自身の account_id を招待した。 */
  SHARE_RECIPIENT_SELF: 'SHARE_RECIPIENT_SELF',
  // avatar-upload で追加 (api-contract-delta.md §0.2)
  /** リクエスト（ファイル）がサイズ上限を超えた。本機能では 5MiB 超。 */
  PAYLOAD_TOO_LARGE: 'PAYLOAD_TOO_LARGE',
  /** 受理しないファイル形式。本機能では JPEG / PNG 以外（HEIC を含む）。 */
  UNSUPPORTED_MEDIA_TYPE: 'UNSUPPORTED_MEDIA_TYPE',
  /** 依存先の設定・準備が整っておらず機能が一時的に使えない。ストレージ未設定 / user_avatars 未作成。 */
  SERVICE_UNAVAILABLE: 'SERVICE_UNAVAILABLE',
} as const;

export type ErrorCode = (typeof ErrorCode)[keyof typeof ErrorCode];

/** 各エラーコードの既定 HTTP ステータス。 */
export const ERROR_CODE_STATUS: Record<ErrorCode, number> = {
  [ErrorCode.VALIDATION_ERROR]: HttpStatus.BAD_REQUEST,
  [ErrorCode.UNAUTHENTICATED]: HttpStatus.UNAUTHORIZED,
  [ErrorCode.AUTH_APPLE_INVALID]: HttpStatus.UNAUTHORIZED,
  [ErrorCode.AUTH_REFRESH_INVALID]: HttpStatus.UNAUTHORIZED,
  [ErrorCode.FORBIDDEN]: HttpStatus.FORBIDDEN,
  [ErrorCode.PLAN_LIMIT_IDENTITY]: HttpStatus.FORBIDDEN,
  [ErrorCode.PLAN_LIMIT_SHARE]: HttpStatus.FORBIDDEN,
  [ErrorCode.NOT_FOUND]: HttpStatus.NOT_FOUND,
  [ErrorCode.SHARE_INVALID]: HttpStatus.NOT_FOUND,
  [ErrorCode.CONFLICT]: HttpStatus.CONFLICT,
  [ErrorCode.INTERNAL]: HttpStatus.INTERNAL_SERVER_ERROR,
  [ErrorCode.AUTH_GOOGLE_INVALID]: HttpStatus.UNAUTHORIZED,
  [ErrorCode.AUTH_CREDENTIALS_INVALID]: HttpStatus.UNAUTHORIZED,
  [ErrorCode.AUTH_RESET_CODE_INVALID]: HttpStatus.UNAUTHORIZED,
  [ErrorCode.EMAIL_ALREADY_REGISTERED]: HttpStatus.CONFLICT,
  [ErrorCode.PLAN_LIMIT_SHARE_WRITE]: HttpStatus.FORBIDDEN,
  [ErrorCode.RATE_LIMITED]: HttpStatus.TOO_MANY_REQUESTS,
  [ErrorCode.SHARE_NOT_INVITED]: HttpStatus.FORBIDDEN,
  [ErrorCode.SHARE_RECIPIENT_UNKNOWN]: HttpStatus.BAD_REQUEST,
  [ErrorCode.SHARE_RECIPIENT_SELF]: HttpStatus.BAD_REQUEST,
  [ErrorCode.PAYLOAD_TOO_LARGE]: HttpStatus.PAYLOAD_TOO_LARGE,
  [ErrorCode.UNSUPPORTED_MEDIA_TYPE]: HttpStatus.UNSUPPORTED_MEDIA_TYPE,
  [ErrorCode.SERVICE_UNAVAILABLE]: HttpStatus.SERVICE_UNAVAILABLE,
};

/**
 * NestJS 標準例外 (ValidationPipe の BadRequestException 等) の
 * HTTP ステータスを契約上のエラーコードに写す。未知は INTERNAL。
 */
export function errorCodeFromStatus(status: number): ErrorCode {
  switch (status) {
    case HttpStatus.BAD_REQUEST:
      return ErrorCode.VALIDATION_ERROR;
    case HttpStatus.UNAUTHORIZED:
      return ErrorCode.UNAUTHENTICATED;
    case HttpStatus.FORBIDDEN:
      return ErrorCode.FORBIDDEN;
    case HttpStatus.NOT_FOUND:
      return ErrorCode.NOT_FOUND;
    case HttpStatus.CONFLICT:
      return ErrorCode.CONFLICT;
    case HttpStatus.TOO_MANY_REQUESTS:
      return ErrorCode.RATE_LIMITED;
    case HttpStatus.PAYLOAD_TOO_LARGE:
      return ErrorCode.PAYLOAD_TOO_LARGE;
    case HttpStatus.UNSUPPORTED_MEDIA_TYPE:
      return ErrorCode.UNSUPPORTED_MEDIA_TYPE;
    case HttpStatus.SERVICE_UNAVAILABLE:
      return ErrorCode.SERVICE_UNAVAILABLE;
    default:
      return ErrorCode.INTERNAL;
  }
}
