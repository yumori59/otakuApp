import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { KeyObject } from 'node:crypto';
import { RemoteJwksProvider } from './oidc/remote-jwks.provider';

export const DEFAULT_APPLE_JWKS_URL = 'https://appleid.apple.com/auth/keys';

export { FORCED_FETCH_COOLDOWN_MS } from './oidc/remote-jwks.provider';

/** identity token の kid から Apple の公開鍵を解決する。 */
export abstract class AppleJwksProvider {
  abstract getPublicKey(kid: string): Promise<KeyObject | null>;
}

/**
 * Apple の JWKS (`APPLE_JWKS_URL`) を取得してキャッシュする。
 * キャッシュ・強制再取得の cooldown は RemoteJwksProvider を参照。
 */
@Injectable()
export class RemoteAppleJwksProvider extends RemoteJwksProvider {
  constructor(private readonly config: ConfigService) {
    super();
  }

  protected jwksUrl(): string {
    return this.config.get<string>('APPLE_JWKS_URL') ?? DEFAULT_APPLE_JWKS_URL;
  }

  protected get issuerLabel(): string {
    return 'Apple';
  }
}
