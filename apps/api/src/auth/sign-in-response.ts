import {
  AuthUser,
  IssuedAccessToken,
  IssuedRefreshToken,
} from './auth.service';
import { SignInResponse, TOKEN_TYPE, TokenPairResponse } from './auth.types';

/**
 * apple / google / register / login / password-reset のレスポンスを 1 箇所で組む。
 * 5 経路が完全に同形であることを保証する（api-contract-delta.md §1 / AC-GA-13）。
 */
export function toSignInResponse(
  user: AuthUser,
  access: IssuedAccessToken,
  refresh: IssuedRefreshToken,
): SignInResponse {
  return {
    ...toTokenPairResponse(access, refresh),
    user: {
      id: user.userId,
      account_id: user.accountId,
      display_name: user.displayName,
      plan: user.plan,
      is_new: user.isNew,
    },
  };
}

/** `POST /v1/auth/refresh` / `POST /v1/auth/password` のレスポンス。 */
export function toTokenPairResponse(
  access: IssuedAccessToken,
  refresh: IssuedRefreshToken,
): TokenPairResponse {
  return {
    access_token: access.accessToken,
    refresh_token: refresh.token,
    expires_in: access.expiresIn,
    token_type: TOKEN_TYPE,
  };
}
