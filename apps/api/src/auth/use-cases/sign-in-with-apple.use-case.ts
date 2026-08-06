import { Injectable } from '@nestjs/common';
import { AppleTokenVerifier } from '../apple-token.verifier';
import { AuthService } from '../auth.service';
import { AppleSignInResponse, TOKEN_TYPE } from '../auth.types';
import { AppleSignInDto } from '../dto/apple-sign-in.dto';

/**
 * Sign in with Apple → ユーザー find-or-create → トークン発行（api-contract.md §1）。
 */
@Injectable()
export class SignInWithAppleUseCase {
  constructor(
    private readonly verifier: AppleTokenVerifier,
    private readonly auth: AuthService,
  ) {}

  async execute(dto: AppleSignInDto): Promise<AppleSignInResponse> {
    const claims = await this.verifier.verify(dto.identity_token, dto.nonce);

    const user = await this.auth.findOrCreateAppleUser(claims);
    const access = await this.auth.issueAccessToken(user.userId);
    const refresh = await this.auth.issueRefreshToken(user.userId);

    return {
      access_token: access.accessToken,
      refresh_token: refresh.token,
      expires_in: access.expiresIn,
      token_type: TOKEN_TYPE,
      user: {
        id: user.userId,
        account_id: user.accountId,
        display_name: user.displayName,
        plan: user.plan,
        is_new: user.isNew,
      },
    };
  }
}
