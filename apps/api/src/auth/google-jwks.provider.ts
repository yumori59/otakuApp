import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { KeyObject } from 'node:crypto';
import { RemoteJwksProvider } from './oidc/remote-jwks.provider';

export const DEFAULT_GOOGLE_JWKS_URL =
  'https://www.googleapis.com/oauth2/v3/certs';

/** id_token の kid から Google の公開鍵を解決する。 */
export abstract class GoogleJwksProvider {
  abstract getPublicKey(kid: string): Promise<KeyObject | null>;
}

/**
 * Google の JWKS (`GOOGLE_JWKS_URL`) を取得してキャッシュする。
 * キャッシュ・強制再取得の cooldown は RemoteJwksProvider を参照（Apple と同じ実装）。
 */
@Injectable()
export class RemoteGoogleJwksProvider extends RemoteJwksProvider {
  constructor(private readonly config: ConfigService) {
    super();
  }

  protected jwksUrl(): string {
    return (
      this.config.get<string>('GOOGLE_JWKS_URL') ?? DEFAULT_GOOGLE_JWKS_URL
    );
  }

  protected get issuerLabel(): string {
    return 'Google';
  }
}
