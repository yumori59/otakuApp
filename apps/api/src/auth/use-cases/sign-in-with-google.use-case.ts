import { Injectable } from '@nestjs/common';
import { AuthService } from '../auth.service';
import { SignInResponse } from '../auth.types';
import { GoogleSignInDto } from '../dto/google-sign-in.dto';
import { GoogleTokenVerifier } from '../google-token.verifier';
import { toSignInResponse } from '../sign-in-response';

/**
 * Google Sign-In → ユーザー find-or-create → トークン発行（api-contract-delta.md §1）。
 * レスポンスは `POST /v1/auth/apple` と完全に同形（AC-GA-13）。
 */
@Injectable()
export class SignInWithGoogleUseCase {
  constructor(
    private readonly verifier: GoogleTokenVerifier,
    private readonly auth: AuthService,
  ) {}

  async execute(dto: GoogleSignInDto): Promise<SignInResponse> {
    const claims = await this.verifier.verify(dto.id_token, dto.nonce);

    const user = await this.auth.findOrCreateGoogleUser(claims);
    const access = await this.auth.issueAccessToken(user.userId);
    const refresh = await this.auth.issueRefreshToken(user.userId);

    return toSignInResponse(user, access, refresh);
  }
}
