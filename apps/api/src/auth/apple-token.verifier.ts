import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { AppleJwksProvider } from './apple-jwks.provider';
import { verifyOidcIdToken } from './oidc/jwt-rs256';

export const DEFAULT_APPLE_ISSUER = 'https://appleid.apple.com';

/** Sign in with Apple の identity token から取り出す確定済みクレーム。 */
export interface AppleIdentityClaims {
  /** Apple のユーザー識別子（`users.apple_sub`）。 */
  sub: string;
  /** 初回サインイン時のみ Apple が返す。以降は null。 */
  email: string | null;
}

/** DI トークン兼インターフェース。spec はこれをスタブに差し替える。 */
export abstract class AppleTokenVerifier {
  abstract verify(
    identityToken: string,
    nonce?: string,
  ): Promise<AppleIdentityClaims>;
}

/**
 * Apple JWKS の公開鍵で identity token を検証する（FR-AUTH-1）。
 * 署名・`iss`・`aud`・`exp`・（req が nonce を送っている場合のみ）`nonce` を確認する。
 * 検証に失敗したものは理由に依らず AUTH_APPLE_INVALID 401（E-14）。
 */
@Injectable()
export class AppleIdentityTokenVerifier extends AppleTokenVerifier {
  constructor(
    private readonly config: ConfigService,
    private readonly jwks: AppleJwksProvider,
  ) {
    super();
  }

  async verify(
    identityToken: string,
    nonce?: string,
  ): Promise<AppleIdentityClaims> {
    // 設定漏れで aud 検証を素通しさせない（設定不備は 500）
    const audience = this.config.get<string>('APPLE_CLIENT_ID');
    if (!audience) {
      throw new AppError(
        ErrorCode.INTERNAL,
        'APPLE_CLIENT_ID is not configured',
      );
    }
    const issuer =
      this.config.get<string>('APPLE_ISSUER') ?? DEFAULT_APPLE_ISSUER;

    const payload = await verifyOidcIdToken({
      idToken: identityToken,
      jwks: this.jwks,
      issuers: [issuer],
      audiences: [audience],
      nonce,
      invalid: appleInvalid,
    });

    return {
      sub: payload.sub as string,
      email: typeof payload.email === 'string' ? payload.email : null,
    };
  }
}

function appleInvalid(message: string): AppError {
  return new AppError(ErrorCode.AUTH_APPLE_INVALID, message);
}
