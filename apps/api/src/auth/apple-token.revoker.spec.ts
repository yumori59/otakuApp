import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  createPublicKey,
  generateKeyPairSync,
  verify as verifySignature,
} from 'node:crypto';
import {
  APPLE_CLIENT_SECRET_MAX_TTL_SECONDS,
  APPLE_REVOKE_URL,
  APPLE_TOKEN_URL,
  AppleSignInTokenRevoker,
} from './apple-token.revoker';

const CLIENT_ID = 'com.example.meigicho';
const TEAM_ID = 'TEAM123456';
const KEY_ID = 'KEY1234567';
const AUTHORIZATION_CODE = 'c1a2b3-authorization-code';
const REFRESH_TOKEN = 'r1e2f3-refresh-token';
const ACCESS_TOKEN = 'a1c2c3-access-token';

const { privateKey, publicKey } = generateKeyPairSync('ec', {
  namedCurve: 'P-256',
  privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  publicKeyEncoding: { type: 'spki', format: 'pem' },
});
/** .env に 1 行で書かれた .p8（改行が `\n` エスケープされた形）。 */
const ESCAPED_PRIVATE_KEY = privateKey.replace(/\n/g, '\\n');

function env(overrides: Record<string, string | undefined> = {}) {
  return {
    APPLE_CLIENT_ID: CLIENT_ID,
    APPLE_TEAM_ID: TEAM_ID,
    APPLE_KEY_ID: KEY_ID,
    APPLE_PRIVATE_KEY: privateKey,
    ...overrides,
  } as Record<string, string | undefined>;
}

function configStub(values: Record<string, string | undefined>): ConfigService {
  return {
    get: jest.fn((key: string) => values[key]),
  } as unknown as ConfigService;
}

interface CapturedRequest {
  url: string;
  init: RequestInit;
  form: URLSearchParams;
}

function requests(fetchMock: jest.Mock): CapturedRequest[] {
  return (fetchMock.mock.calls as [string, RequestInit][]).map(
    ([url, init]) => ({
      url,
      init,
      form: new URLSearchParams(String(init.body)),
    }),
  );
}

/** 1 段目: `POST /auth/token`（authorization_code → refresh_token 交換）。 */
function tokenExchange(fetchMock: jest.Mock): CapturedRequest {
  const [first] = requests(fetchMock);
  expect(first?.url).toBe(APPLE_TOKEN_URL);
  return first;
}

/** 2 段目: `POST /auth/revoke`（refresh_token の失効）。 */
function revocation(fetchMock: jest.Mock): CapturedRequest {
  const captured = requests(fetchMock);
  expect(captured).toHaveLength(2);
  expect(captured[1].url).toBe(APPLE_REVOKE_URL);
  return captured[1];
}

/** Apple の `/auth/token` 成功応答（本物と同じキー構成）。 */
function tokenResponse(
  body: Record<string, unknown> = {
    access_token: ACCESS_TOKEN,
    token_type: 'Bearer',
    expires_in: 3600,
    refresh_token: REFRESH_TOKEN,
    id_token: 'header.payload.signature',
  },
) {
  return { ok: true, status: 200, json: () => Promise.resolve(body) };
}

function decodeSegment(segment: string): Record<string, unknown> {
  return JSON.parse(
    Buffer.from(segment, 'base64url').toString('utf8'),
  ) as Record<string, unknown>;
}

describe('AppleSignInTokenRevoker', () => {
  let fetchMock: jest.Mock;
  let logged: string[];

  beforeEach(() => {
    fetchMock = jest.fn((url: string) =>
      Promise.resolve(
        url === APPLE_TOKEN_URL
          ? tokenResponse()
          : { ok: true, status: 200, json: () => Promise.resolve({}) },
      ),
    );
    global.fetch = fetchMock as unknown as typeof fetch;

    logged = [];
    const record = (...args: unknown[]) => {
      logged.push(args.map((a) => String(a)).join(' '));
      return undefined;
    };
    for (const level of ['log', 'warn', 'error', 'debug', 'verbose'] as const) {
      jest.spyOn(Logger.prototype, level).mockImplementation(record);
    }
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  function revoker(
    values: Record<string, string | undefined> = env(),
  ): AppleSignInTokenRevoker {
    return new AppleSignInTokenRevoker(configStub(values));
  }

  describe('鍵の設定', () => {
    it.each([
      'APPLE_CLIENT_ID',
      'APPLE_TEAM_ID',
      'APPLE_KEY_ID',
      'APPLE_PRIVATE_KEY',
    ])('AC-AD-11 %s が未設定なら失効をスキップして成功扱いにする', async (key) => {
      const target = revoker(env({ [key]: undefined }));

      await expect(
        target.revokeAuthorizationCode(AUTHORIZATION_CODE),
      ).resolves.toBeUndefined();

      expect(fetchMock).not.toHaveBeenCalled();
    });

    it('AC-AD-11 空文字の設定も未設定として扱う（compose の既定値）', async () => {
      const target = revoker(env({ APPLE_PRIVATE_KEY: '' }));

      await expect(
        target.revokeAuthorizationCode(AUTHORIZATION_CODE),
      ).resolves.toBeUndefined();

      expect(fetchMock).not.toHaveBeenCalled();
    });

    it('authorization_code が空なら失効 API を呼ばない', async () => {
      await expect(revoker().revokeAuthorizationCode('')).resolves.toBeUndefined();

      expect(fetchMock).not.toHaveBeenCalled();
    });
  });

  describe('失効リクエスト（2 段階: /auth/token → /auth/revoke）', () => {
    it('1 段目は /auth/token へ grant_type=authorization_code で交換する', async () => {
      await revoker().revokeAuthorizationCode(AUTHORIZATION_CODE);

      const req = tokenExchange(fetchMock);
      expect(req.init.method).toBe('POST');
      expect(
        String(
          (req.init.headers as Record<string, string>)['Content-Type'],
        ).toLowerCase(),
      ).toContain('application/x-www-form-urlencoded');
      expect(req.form.get('client_id')).toBe(CLIENT_ID);
      expect(req.form.get('code')).toBe(AUTHORIZATION_CODE);
      expect(req.form.get('grant_type')).toBe('authorization_code');
      expect(req.form.get('client_secret')).toBeTruthy();
      // /auth/token は token / token_type_hint を取らない
      expect(req.form.get('token')).toBeNull();
      expect(req.form.get('token_type_hint')).toBeNull();
    });

    it('2 段目は交換で得た refresh_token を /auth/revoke へ送る', async () => {
      await revoker().revokeAuthorizationCode(AUTHORIZATION_CODE);

      const req = revocation(fetchMock);
      expect(req.init.method).toBe('POST');
      expect(
        String(
          (req.init.headers as Record<string, string>)['Content-Type'],
        ).toLowerCase(),
      ).toContain('application/x-www-form-urlencoded');
      expect(req.form.get('client_id')).toBe(CLIENT_ID);
      expect(req.form.get('token')).toBe(REFRESH_TOKEN);
      // Apple の /auth/revoke は refresh_token / access_token しか受け付けない
      expect(req.form.get('token_type_hint')).toBe('refresh_token');
      expect(req.form.get('client_secret')).toBeTruthy();
      // authorization_code をそのまま失効に投げてはならない
      expect(String(req.init.body)).not.toContain(AUTHORIZATION_CODE);
    });

    it('交換に refresh_token が無ければ失効を呼ばない（例外にもしない）', async () => {
      fetchMock.mockImplementation((url: string) =>
        Promise.resolve(
          url === APPLE_TOKEN_URL
            ? tokenResponse({ access_token: ACCESS_TOKEN })
            : { ok: true, status: 200, json: () => Promise.resolve({}) },
        ),
      );

      await expect(
        revoker().revokeAuthorizationCode(AUTHORIZATION_CODE),
      ).resolves.toBeUndefined();

      expect(requests(fetchMock).map((r) => r.url)).toEqual([APPLE_TOKEN_URL]);
    });

    it('交換が 4xx なら失効を呼ばない（例外にもしない）', async () => {
      fetchMock.mockImplementation((url: string) =>
        Promise.resolve(
          url === APPLE_TOKEN_URL
            ? { ok: false, status: 400, json: () => Promise.resolve({}) }
            : { ok: true, status: 200, json: () => Promise.resolve({}) },
        ),
      );

      await expect(
        revoker().revokeAuthorizationCode(AUTHORIZATION_CODE),
      ).resolves.toBeUndefined();

      expect(requests(fetchMock).map((r) => r.url)).toEqual([APPLE_TOKEN_URL]);
    });

    it('client_secret は ES256 / kid=APPLE_KEY_ID の JWT である', async () => {
      await revoker().revokeAuthorizationCode(AUTHORIZATION_CODE);

      for (const req of requests(fetchMock)) {
        const clientSecret = req.form.get('client_secret') ?? '';
        const [encodedHeader] = clientSecret.split('.');

        expect(clientSecret.split('.')).toHaveLength(3);
        expect(decodeSegment(encodedHeader)).toMatchObject({
          alg: 'ES256',
          kid: KEY_ID,
        });
      }
    });

    it('client_secret の iss / sub / aud / exp が Apple の要求どおり', async () => {
      const before = Math.floor(Date.now() / 1000);

      await revoker().revokeAuthorizationCode(AUTHORIZATION_CODE);

      const clientSecret = revocation(fetchMock).form.get('client_secret') ?? '';
      const payload = decodeSegment(clientSecret.split('.')[1]);

      expect(payload.iss).toBe(TEAM_ID);
      expect(payload.sub).toBe(CLIENT_ID);
      expect(payload.aud).toBe('https://appleid.apple.com');
      expect(typeof payload.iat).toBe('number');
      expect(payload.iat as number).toBeGreaterThanOrEqual(before);
      const ttl = (payload.exp as number) - (payload.iat as number);
      expect(ttl).toBeGreaterThan(0);
      // Apple の上限は 6 か月（15777000 秒）
      expect(ttl).toBeLessThanOrEqual(APPLE_CLIENT_SECRET_MAX_TTL_SECONDS);
    });

    it('client_secret の署名が .p8 の公開鍵で検証できる（JWS 形式の r||s）', async () => {
      await revoker().revokeAuthorizationCode(AUTHORIZATION_CODE);

      const clientSecret = revocation(fetchMock).form.get('client_secret') ?? '';
      const [header, payload, signature] = clientSecret.split('.');

      const ok = verifySignature(
        'SHA256',
        Buffer.from(`${header}.${payload}`, 'ascii'),
        { key: createPublicKey(publicKey), dsaEncoding: 'ieee-p1363' },
        Buffer.from(signature, 'base64url'),
      );
      expect(ok).toBe(true);
    });

    it('.env で改行が \\n にエスケープされた秘密鍵でも署名できる', async () => {
      await revoker(
        env({ APPLE_PRIVATE_KEY: ESCAPED_PRIVATE_KEY }),
      ).revokeAuthorizationCode(AUTHORIZATION_CODE);

      expect(revocation(fetchMock).form.get('client_secret')).toBeTruthy();
    });
  });

  describe('ベストエフォート（AC-AD-12 / E-7）', () => {
    it('fetch が例外を投げても呼び出し元に伝播させない', async () => {
      fetchMock.mockRejectedValue(new Error('network unreachable'));

      await expect(
        revoker().revokeAuthorizationCode(AUTHORIZATION_CODE),
      ).resolves.toBeUndefined();
    });

    it('Apple が 4xx/5xx を返しても例外にしない', async () => {
      fetchMock.mockImplementation((url: string) =>
        Promise.resolve(
          url === APPLE_TOKEN_URL
            ? tokenResponse()
            : { ok: false, status: 400, json: () => Promise.resolve({}) },
        ),
      );

      await expect(
        revoker().revokeAuthorizationCode(AUTHORIZATION_CODE),
      ).resolves.toBeUndefined();

      expect(requests(fetchMock)).toHaveLength(2);
    });

    it('交換応答が JSON でなくても例外にしない', async () => {
      fetchMock.mockImplementation(() =>
        Promise.resolve({
          ok: true,
          status: 200,
          json: () => Promise.reject(new SyntaxError('Unexpected token <')),
        }),
      );

      await expect(
        revoker().revokeAuthorizationCode(AUTHORIZATION_CODE),
      ).resolves.toBeUndefined();
    });

    it('秘密鍵が壊れていても例外にしない', async () => {
      await expect(
        revoker(
          env({ APPLE_PRIVATE_KEY: 'not-a-pem' }),
        ).revokeAuthorizationCode(AUTHORIZATION_CODE),
      ).resolves.toBeUndefined();

      expect(fetchMock).not.toHaveBeenCalled();
    });
  });

  describe('NFR-AD-3 秘密値をログに出さない', () => {
    function assertNoSecretsLogged(): void {
      const dumped = logged.join('\n');
      expect(dumped).not.toContain(AUTHORIZATION_CODE);
      expect(dumped).not.toContain(REFRESH_TOKEN);
      expect(dumped).not.toContain(ACCESS_TOKEN);
      expect(dumped).not.toContain('BEGIN PRIVATE KEY');
      for (const line of privateKey.split('\n').filter((l) => l.length > 16)) {
        expect(dumped).not.toContain(line);
      }
    }

    it('成功時にコード・秘密鍵・client_secret をログに出さない', async () => {
      await revoker().revokeAuthorizationCode(AUTHORIZATION_CODE);

      assertNoSecretsLogged();
      for (const req of requests(fetchMock)) {
        expect(logged.join('\n')).not.toContain(
          req.form.get('client_secret') ?? '',
        );
      }
    });

    it('失効 API が失敗してもコード・秘密鍵をログに出さない', async () => {
      fetchMock.mockRejectedValue(new Error(`failed for ${AUTHORIZATION_CODE}`));

      await revoker().revokeAuthorizationCode(AUTHORIZATION_CODE);

      assertNoSecretsLogged();
    });

    it('交換応答の refresh_token / access_token をログに出さない', async () => {
      fetchMock.mockImplementation((url: string) =>
        Promise.resolve(
          url === APPLE_TOKEN_URL
            ? tokenResponse()
            : { ok: false, status: 400, json: () => Promise.resolve({}) },
        ),
      );

      await revoker().revokeAuthorizationCode(AUTHORIZATION_CODE);

      assertNoSecretsLogged();
    });

    it('鍵未設定のスキップ warn にもコードを含めない', async () => {
      await revoker(env({ APPLE_TEAM_ID: undefined })).revokeAuthorizationCode(
        AUTHORIZATION_CODE,
      );

      assertNoSecretsLogged();
      expect(logged.join('\n')).not.toBe('');
    });
  });
});
