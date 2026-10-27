import { HttpStatus } from '@nestjs/common';
import {
  ERROR_CODE_STATUS,
  ErrorCode,
  errorCodeFromStatus,
} from './error-codes';

describe('error-codes (backend-auth-and-shares-extension)', () => {
  it('AC-T0-01 追加した 6 コードが ERROR_CODE_STATUS に契約どおりのステータスで載っている', () => {
    expect(ERROR_CODE_STATUS[ErrorCode.AUTH_GOOGLE_INVALID]).toBe(
      HttpStatus.UNAUTHORIZED,
    );
    expect(ERROR_CODE_STATUS[ErrorCode.AUTH_CREDENTIALS_INVALID]).toBe(
      HttpStatus.UNAUTHORIZED,
    );
    expect(ERROR_CODE_STATUS[ErrorCode.AUTH_RESET_CODE_INVALID]).toBe(
      HttpStatus.UNAUTHORIZED,
    );
    expect(ERROR_CODE_STATUS[ErrorCode.EMAIL_ALREADY_REGISTERED]).toBe(
      HttpStatus.CONFLICT,
    );
    expect(ERROR_CODE_STATUS[ErrorCode.PLAN_LIMIT_SHARE_WRITE]).toBe(
      HttpStatus.FORBIDDEN,
    );
    expect(ERROR_CODE_STATUS[ErrorCode.RATE_LIMITED]).toBe(
      HttpStatus.TOO_MANY_REQUESTS,
    );
  });

  it('AC-T0-02 errorCodeFromStatus(429) === RATE_LIMITED', () => {
    expect(errorCodeFromStatus(429)).toBe(ErrorCode.RATE_LIMITED);
  });
});

describe('error-codes (avatar-upload)', () => {
  it('AC-AV-20 追加した 3 コードが ERROR_CODE_STATUS に契約どおりのステータスで載っている', () => {
    expect(ERROR_CODE_STATUS[ErrorCode.PAYLOAD_TOO_LARGE]).toBe(413);
    expect(ERROR_CODE_STATUS[ErrorCode.UNSUPPORTED_MEDIA_TYPE]).toBe(415);
    expect(ERROR_CODE_STATUS[ErrorCode.SERVICE_UNAVAILABLE]).toBe(503);
  });

  it('AC-AV-20 errorCodeFromStatus(413) === PAYLOAD_TOO_LARGE', () => {
    expect(errorCodeFromStatus(413)).toBe(ErrorCode.PAYLOAD_TOO_LARGE);
  });

  it('AC-AV-20 errorCodeFromStatus(415) === UNSUPPORTED_MEDIA_TYPE', () => {
    expect(errorCodeFromStatus(415)).toBe(ErrorCode.UNSUPPORTED_MEDIA_TYPE);
  });

  it('AC-AV-20 errorCodeFromStatus(503) === SERVICE_UNAVAILABLE', () => {
    expect(errorCodeFromStatus(503)).toBe(ErrorCode.SERVICE_UNAVAILABLE);
  });
});

describe('error-codes (share-account-invites)', () => {
  it('AC-SI-T1-01 追加 3 コードが api-contract-delta.md §0.1 のステータスで載っている', () => {
    expect(ERROR_CODE_STATUS[ErrorCode.SHARE_NOT_INVITED]).toBe(
      HttpStatus.FORBIDDEN,
    );
    expect(ERROR_CODE_STATUS[ErrorCode.SHARE_RECIPIENT_UNKNOWN]).toBe(
      HttpStatus.BAD_REQUEST,
    );
    expect(ERROR_CODE_STATUS[ErrorCode.SHARE_RECIPIENT_SELF]).toBe(
      HttpStatus.BAD_REQUEST,
    );
  });

  it('AC-SI-T1-02 SHARE_INVALID は 404 のまま（招待外も 404 に落とすため）', () => {
    expect(ERROR_CODE_STATUS[ErrorCode.SHARE_INVALID]).toBe(
      HttpStatus.NOT_FOUND,
    );
  });
});
