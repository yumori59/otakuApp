import { Plan } from '../entitlements/entitlements.service';

/** api-contract.md §1 のトークンレスポンス（JSON キーは snake_case）。 */
export interface TokenPairResponse {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  token_type: 'Bearer';
}

export interface SignedInUser {
  id: string;
  account_id: string | null;
  display_name: string | null;
  plan: Plan;
  /** このリクエストで users 行を新規作成したか（iOS のオンボーディング分岐用）。 */
  is_new: boolean;
}

/**
 * サインイン系（apple / google / register / login / password reset）共通のレスポンス。
 * api-contract-delta.md §1 のとおり 5 経路すべて同形。
 */
export interface SignInResponse extends TokenPairResponse {
  user: SignedInUser;
}

/** @deprecated `SignInResponse` を使う（Apple 専用ではなくなったため）。 */
export type AppleSignInResponse = SignInResponse;

export const TOKEN_TYPE = 'Bearer' as const;
