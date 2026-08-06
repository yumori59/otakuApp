import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { GoogleJwksProvider } from './google-jwks.provider';
import { verifyOidcIdToken } from './oidc/jwt-rs256';

/**
 * `GOOGLE_ISSUER` 未設定時に受理する iss。
 * Google はスキーマ付き / 無しの両方を発行しうるので両方を受理する
 * （api-contract-delta.md §0 の環境変数表）。
 */
export const DEFAULT_GOOGLE_ISSUERS = [
  'https://accounts.google.com',
  'accounts.google.com',
] as const;

/** Google Sign-In の id_token から取り出す確定済みクレーム。 */
export interface GoogleIdentityClaims {
  /** Google のユーザー識別子（`users.google_sub`）。 */
  sub: string;
  /** `email_verified === true` のときだけ値が入る。それ以外は null。 */
  email: string | null;
}

/** DI トークン兼インターフェース。spec はこれをスタブに差し替える。 */
export abstract class GoogleTokenVerifier {
  abstract verify(
    idToken: string,
    nonce?: string,
  ): Promise<GoogleIdentityClaims>;
}

/**
 * Google JWKS の公開鍵で id_token を検証する（FR-GA-1）。
 * 検証に失敗したものは理由に依らず AUTH_GOOGLE_INVALID 401（api-contract-delta.md §0）。
 */
@Injectable()
export class GoogleIdentityTokenVerifier extends GoogleTokenVerifier {
  constructor(
    private readonly config: ConfigService,
    private readonly jwks: GoogleJwksProvider,
  ) {
    super();
  }

  async verify(
    idToken: string,
    nonce?: string,
  ): Promise<GoogleIdentityClaims> {
    // 設定漏れで aud 検証を素通しさせない（設定不備は 500）
    const audiences = this.clientIds();
    if (audiences.length === 0) {
      throw new AppError(
        ErrorCode.INTERNAL,
        'GOOGLE_CLIENT_IDS is not configured',
      );
    }

    const payload = await verifyOidcIdToken({
      idToken,
      jwks: this.jwks,
      issuers: this.issuers(),
      audiences,
      nonce,
      invalid: googleInvalid,
    });

    // email_verified が厳密に true のときだけ email を採用する（文字列 "true" は受理しない）
    const verified = payload.email_verified === true;
    return {
      sub: payload.sub as string,
      email:
        verified && typeof payload.email === 'string' ? payload.email : null,
    };
  }

  /** `GOOGLE_CLIENT_IDS` のカンマ区切りリスト。空要素は捨てる。 */
  private clientIds(): string[] {
    const raw = this.config.get<string>('GOOGLE_CLIENT_IDS') ?? '';
    return raw
      .split(',')
      .map((value) => value.trim())
      .filter((value) => value.length > 0);
  }

  /** `GOOGLE_ISSUER` 設定時はその値のみ。未設定なら既定 2 種を受理する。 */
  private issuers(): readonly string[] {
    const configured = this.config.get<string>('GOOGLE_ISSUER');
    return configured ? [configured] : DEFAULT_GOOGLE_ISSUERS;
  }
}

function googleInvalid(message: string): AppError {
  return new AppError(ErrorCode.AUTH_GOOGLE_INVALID, message);
}
