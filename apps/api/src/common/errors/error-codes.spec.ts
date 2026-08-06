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
