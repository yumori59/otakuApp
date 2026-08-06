import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createPrivateKey, sign as signPayload } from 'node:crypto';

/**
 * Sign in with Apple のトークン発行エンドポイント（REST API）。
 * `authorization_code` はここで `refresh_token` に交換する（失効は refresh_token に対してしか行えない）。
 */
export const APPLE_TOKEN_URL = 'https://appleid.apple.com/auth/token';
/** Sign in with Apple のトークン失効エンドポイント（REST API）。 */
export const APPLE_REVOKE_URL = 'https://appleid.apple.com/auth/revoke';
/** client_secret JWT の `aud`（Apple 固定）。 */
export const APPLE_CLIENT_SECRET_AUDIENCE = 'https://appleid.apple.com';
/** Apple が許す client_secret の最大有効期間（6 か月）。これを超えると invalid_client になる。 */
export const APPLE_CLIENT_SECRET_MAX_TTL_SECONDS = 15_777_000;
/** 実際に発行する client_secret の TTL。1 リクエストで使い切るので短くする。 */
export const APPLE_CLIENT_SECRET_TTL_SECONDS = 300;
/** 失効 API / トークン交換 API のタイムアウト（JWKS 取得と同じ 5 秒）。 */
export const APPLE_REVOKE_TIMEOUT_MS = 5000;

/**
 * DI トークン兼インターフェース。spec / 他モジュールはこれをスタブに差し替える。
 *
 * **ベストエフォート契約**: 実装は失敗を内部で握り潰し、例外を投げない（D3 / FR-AD-11 / E-7）。
 * 呼び出し元（アカウント削除）は失効の成否をレスポンスに反映してはならない。
 */
export abstract class AppleTokenRevoker {
  /**
   * Sign in with Apple の authorization_code を失効させる。
   * 鍵が未設定なら何もしない。失敗しても throw しない。
   */
  abstract revokeAuthorizationCode(authorizationCode: string): Promise<void>;
}

interface AppleClientCredentials {
  clientId: string;
  teamId: string;
  keyId: string;
  privateKeyPem: string;
}

/**
 * アカウント削除時に Apple 側のトークンを失効させる（App Store Guideline 5.1.1(v) 周辺の運用要件 / FR-AD-11）。
 *
 * Apple の `/auth/revoke` が受け付ける `token` は **`refresh_token` か `access_token` だけ**で、
 * クライアントから受け取る `authorization_code` は直接渡せない。そのため 2 段階で呼ぶ:
 *
 * 1. `POST /auth/token`（`grant_type=authorization_code`）で `refresh_token` を得る
 * 2. `POST /auth/revoke`（`token_type_hint=refresh_token`）で失効させる
 *
 * どちらの段でも失敗はベストエフォートとして warn だけ残し、例外は投げない。
 *
 * client_secret は Apple Developer の .p8（EC P-256）で署名した ES256 JWT。
 * 外部依存を増やさないため `node:crypto` だけで組み立てる（`jsonwebtoken` は入れない）。
 *
 * ログには **authorization_code / 秘密鍵 / 生成した client_secret を一切出さない**（NFR-AD-3）。
 * 例外は種別（`name`）だけを記録する。メッセージや本文は秘密値を含み得るため出さない。
 */
@Injectable()
export class AppleSignInTokenRevoker extends AppleTokenRevoker {
  private readonly logger = new Logger(AppleSignInTokenRevoker.name);

  constructor(private readonly config: ConfigService) {
    super();
  }

  async revokeAuthorizationCode(authorizationCode: string): Promise<void> {
    if (!authorizationCode) return;

    const credentials = this.credentials();
    if (!credentials) {
      this.logger.warn(
        'APPLE_CLIENT_ID / APPLE_TEAM_ID / APPLE_KEY_ID / APPLE_PRIVATE_KEY の' +
          'いずれかが未設定のため Sign in with Apple のトークン失効をスキップしました',
      );
      return;
    }

    try {
      // client_secret は 1 リクエスト分の TTL しかないが、2 段とも同一秒内に使うので使い回す
      const clientSecret = createClientSecret(credentials);
      const refreshToken = await this.exchangeAuthorizationCode(
        credentials,
        clientSecret,
        authorizationCode,
      );
      // 交換に失敗した理由は exchange 側で warn 済み。失効は呼ばない
      if (!refreshToken) return;

      await this.revokeRefreshToken(credentials, clientSecret, refreshToken);
    } catch (error) {
      this.logger.warn(
        `Apple のトークン失効を実行できませんでした: ${errorLabel(error)}`,
      );
    }
  }

  /**
   * 1 段目: `authorization_code` を `refresh_token` に交換する。
   * 応答本文（refresh_token / access_token / id_token）は**一切ログに出さない**（NFR-AD-3）。
   */
  private async exchangeAuthorizationCode(
    credentials: AppleClientCredentials,
    clientSecret: string,
    authorizationCode: string,
  ): Promise<string | null> {
    const body = new URLSearchParams({
      client_id: credentials.clientId,
      client_secret: clientSecret,
      code: authorizationCode,
      grant_type: 'authorization_code',
    });

    const res = await fetch(APPLE_TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
      signal: AbortSignal.timeout(APPLE_REVOKE_TIMEOUT_MS),
    });

    if (!res.ok) {
      this.logger.warn(
        `Apple の authorization_code 交換が失敗しました: status=${res.status}`,
      );
      return null;
    }

    const payload = (await res.json()) as { refresh_token?: unknown } | null;
    const refreshToken = payload?.refresh_token;
    if (typeof refreshToken !== 'string' || !refreshToken) {
      this.logger.warn(
        'Apple のトークン応答に refresh_token が含まれていませんでした',
      );
      return null;
    }
    return refreshToken;
  }

  /** 2 段目: 得た `refresh_token` を失効させる。Apple は成功時 200 / ボディ無し。 */
  private async revokeRefreshToken(
    credentials: AppleClientCredentials,
    clientSecret: string,
    refreshToken: string,
  ): Promise<void> {
    const body = new URLSearchParams({
      client_id: credentials.clientId,
      client_secret: clientSecret,
      token: refreshToken,
      token_type_hint: 'refresh_token',
    });

    const res = await fetch(APPLE_REVOKE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
      signal: AbortSignal.timeout(APPLE_REVOKE_TIMEOUT_MS),
    });

    // 失敗理由の本文はログに残さない
    if (!res.ok) {
      this.logger.warn(
        `Apple のトークン失効が失敗しました: status=${res.status}`,
      );
    }
  }

  /** 4 変数がすべて揃っているときだけ失効を試みる（1 つでも欠けたらスキップ）。 */
  private credentials(): AppleClientCredentials | null {
    const clientId = this.config.get<string>('APPLE_CLIENT_ID');
    const teamId = this.config.get<string>('APPLE_TEAM_ID');
    const keyId = this.config.get<string>('APPLE_KEY_ID');
    const privateKey = this.config.get<string>('APPLE_PRIVATE_KEY');
    if (!clientId || !teamId || !keyId || !privateKey) return null;

    return {
      clientId,
      teamId,
      keyId,
      // .env に 1 行で書かれた .p8（改行が `\n` エスケープされた形）も受け付ける
      privateKeyPem: privateKey.replace(/\\n/g, '\n'),
    };
  }
}

/** ES256（ECDSA P-256 + SHA-256）で署名した client_secret JWT を組み立てる。 */
function createClientSecret(
  credentials: AppleClientCredentials,
  nowMs: number = Date.now(),
): string {
  const issuedAt = Math.floor(nowMs / 1000);
  const header = { alg: 'ES256', kid: credentials.keyId, typ: 'JWT' };
  const payload = {
    iss: credentials.teamId,
    iat: issuedAt,
    exp: issuedAt + APPLE_CLIENT_SECRET_TTL_SECONDS,
    aud: APPLE_CLIENT_SECRET_AUDIENCE,
    sub: credentials.clientId,
  };

  const signingInput = `${encodeSegment(header)}.${encodeSegment(payload)}`;
  // JWS の ES256 は DER ではなく r||s の固定長 64 バイト署名（ieee-p1363）
  const signature = signPayload(
    'SHA256',
    Buffer.from(signingInput, 'ascii'),
    {
      key: createPrivateKey(credentials.privateKeyPem),
      dsaEncoding: 'ieee-p1363',
    },
  );

  return `${signingInput}.${signature.toString('base64url')}`;
}

function encodeSegment(value: unknown): string {
  return Buffer.from(JSON.stringify(value), 'utf8').toString('base64url');
}

/** 秘密値を漏らさないため、例外は種別だけをログに出す（NFR-AD-3）。 */
function errorLabel(error: unknown): string {
  if (error instanceof Error) return error.name;
  return typeof error;
}
