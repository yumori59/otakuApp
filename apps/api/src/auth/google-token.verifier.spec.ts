import { ConfigService } from '@nestjs/config';
import { KeyObject, createSign, generateKeyPairSync } from 'node:crypto';
import { AppError } from '../common/errors/app-error';
import { GoogleJwksProvider } from './google-jwks.provider';
import { GoogleIdentityTokenVerifier } from './google-token.verifier';

const GOOGLE_ISSUER = 'https://accounts.google.com';
const CLIENT_ID_IOS = '111-ios.apps.googleusercontent.com';
const CLIENT_ID_SERVER = '222-server.apps.googleusercontent.com';
const GOOGLE_SUB = '107654321098765432109';
const KID = 'google-key-1';

const ENV: Record<string, string> = {
  GOOGLE_CLIENT_IDS: `${CLIENT_ID_IOS}, ${CLIENT_ID_SERVER}`,
  GOOGLE_JWKS_URL: 'https://www.googleapis.com/oauth2/v3/certs',
};

function configStub(overrides: Record<string, string | undefined> = {}) {
  const env: Record<string, string | undefined> = { ...ENV, ...overrides };
  return {
    get: jest.fn((key: string) => env[key]),
  } as unknown as ConfigService;
}

function base64url(value: string | Buffer): string {
  return Buffer.from(value).toString('base64url');
}

/** Google の id_token を模した RS256 JWT をローカル鍵で生成する（外部通信しない）。 */
function signToken(options: {
  privateKey: KeyObject;
  payload: Record<string, unknown>;
  alg?: string;
  kid?: string | null;
}): string {
  const header: Record<string, unknown> = {
    alg: options.alg ?? 'RS256',
    typ: 'JWT',
  };
  const kid = options.kid === undefined ? KID : options.kid;
  if (kid !== null) header.kid = kid;

  const encodedHeader = base64url(JSON.stringify(header));
  const encodedPayload = base64url(JSON.stringify(options.payload));
  const signature = createSign('RSA-SHA256')
    .update(`${encodedHeader}.${encodedPayload}`)
    .sign(options.privateKey);

  return `${encodedHeader}.${encodedPayload}.${base64url(signature)}`;
}

describe('GoogleIdentityTokenVerifier', () => {
  let privateKey: KeyObject;
  let publicKey: KeyObject;
  let otherPrivateKey: KeyObject;
  let jwks: GoogleJwksProvider;
  let getPublicKey: jest.Mock;

  beforeAll(() => {
    ({ privateKey, publicKey } = generateKeyPairSync('rsa', {
      modulusLength: 2048,
    }));
    ({ privateKey: otherPrivateKey } = generateKeyPairSync('rsa', {
      modulusLength: 2048,
    }));
  });

  beforeEach(() => {
    getPublicKey = jest.fn(async (kid: string) =>
      kid === KID ? publicKey : null,
    );
    jwks = { getPublicKey } as unknown as GoogleJwksProvider;
  });

  function verifier(configOverrides: Record<string, string | undefined> = {}) {
    return new GoogleIdentityTokenVerifier(configStub(configOverrides), jwks);
  }

  function claims(overrides: Record<string, unknown> = {}) {
    const nowSeconds = Math.floor(Date.now() / 1000);
    return {
      iss: GOOGLE_ISSUER,
      aud: CLIENT_ID_IOS,
      sub: GOOGLE_SUB,
      iat: nowSeconds,
      exp: nowSeconds + 600,
      ...overrides,
    };
  }

  function token(
    overrides: Record<string, unknown> = {},
    options: Partial<Parameters<typeof signToken>[0]> = {},
  ) {
    return signToken({ privateKey, payload: claims(overrides), ...options });
  }

  async function statusOf(promise: Promise<unknown>): Promise<number> {
    try {
      await promise;
      throw new Error('expected rejection');
    } catch (error) {
      return (error as AppError).getStatus();
    }
  }

  it('AC-GA-01 有効な id_token から sub を取り出す', async () => {
    await expect(verifier().verify(token())).resolves.toEqual({
      sub: GOOGLE_SUB,
      email: null,
    });
    expect(getPublicKey).toHaveBeenCalledWith(KID);
  });

  it('AC-GA-09 email_verified が true のときだけ email を返す', async () => {
    await expect(
      verifier().verify(token({ email: 'fan@example.com', email_verified: true })),
    ).resolves.toEqual({ sub: GOOGLE_SUB, email: 'fan@example.com' });
  });

  it('AC-GA-09 email_verified が false / 欠落なら email は null', async () => {
    await expect(
      verifier().verify(
        token({ email: 'fan@example.com', email_verified: false }),
      ),
    ).resolves.toEqual({ sub: GOOGLE_SUB, email: null });

    await expect(
      verifier().verify(token({ email: 'fan@example.com' })),
    ).resolves.toEqual({ sub: GOOGLE_SUB, email: null });
  });

  it('AC-GA-09 email_verified が文字列 "true" でも保存対象にしない（黙殺フォールバック禁止・BE-2）', async () => {
    await expect(
      verifier().verify(
        token({ email: 'fan@example.com', email_verified: 'true' }),
      ),
    ).resolves.toEqual({ sub: GOOGLE_SUB, email: null });
  });

  it('AC-GA-03 署名が不正なら AUTH_GOOGLE_INVALID 401', async () => {
    const forged = token({}, { privateKey: otherPrivateKey });

    await expect(verifier().verify(forged)).rejects.toMatchObject({
      code: 'AUTH_GOOGLE_INVALID',
    });
    await expect(verifier().verify(forged)).rejects.toBeInstanceOf(AppError);
    await expect(statusOf(verifier().verify(forged))).resolves.toBe(401);
  });

  it('AC-GA-03 alg: none への摩り替えは 401', async () => {
    const header = base64url(JSON.stringify({ alg: 'none', kid: KID }));
    const payload = base64url(JSON.stringify(claims()));

    await expect(
      verifier().verify(`${header}.${payload}.`),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-03 RS256 以外の alg は 401', async () => {
    await expect(
      verifier().verify(token({}, { alg: 'HS256' })),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-04 aud がリストに無ければ 401', async () => {
    await expect(
      verifier().verify(token({ aud: 'com.other.app' })),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-04 GOOGLE_CLIENT_IDS のどれかに一致すれば通る（カンマ区切り・空白許容）', async () => {
    await expect(
      verifier().verify(token({ aud: CLIENT_ID_SERVER })),
    ).resolves.toMatchObject({ sub: GOOGLE_SUB });
  });

  it('AC-GA-05 GOOGLE_ISSUER 未設定なら accounts.google.com（スキーマ無し）も受理する', async () => {
    const configured = verifier({ GOOGLE_ISSUER: undefined });

    await expect(
      configured.verify(token({ iss: 'accounts.google.com' })),
    ).resolves.toMatchObject({ sub: GOOGLE_SUB });
    await expect(
      configured.verify(token({ iss: 'https://accounts.google.com' })),
    ).resolves.toMatchObject({ sub: GOOGLE_SUB });
  });

  it('AC-GA-05 GOOGLE_ISSUER 設定時はその値以外を受理しない', async () => {
    const configured = verifier({ GOOGLE_ISSUER: 'https://accounts.google.com' });

    await expect(
      configured.verify(token({ iss: 'accounts.google.com' })),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-05 iss が Google 以外なら 401', async () => {
    await expect(
      verifier().verify(token({ iss: 'https://evil.example.com' })),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-06 exp 切れなら 401', async () => {
    await expect(
      verifier().verify(token({ exp: Math.floor(Date.now() / 1000) - 1 })),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-06 exp が無い token は 401', async () => {
    await expect(
      verifier().verify(token({ exp: undefined })),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-06 sub が無い token は 401', async () => {
    await expect(
      verifier().verify(token({ sub: undefined })),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-07 req の nonce と token の nonce が一致すれば通る', async () => {
    await expect(
      verifier().verify(token({ nonce: 'nonce-abc' }), 'nonce-abc'),
    ).resolves.toMatchObject({ sub: GOOGLE_SUB });
  });

  it('AC-GA-07 req の nonce と token の nonce が不一致なら 401', async () => {
    await expect(
      verifier().verify(token({ nonce: 'nonce-abc' }), 'nonce-different'),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-07 req に nonce があるのに token に nonce が無ければ 401', async () => {
    await expect(verifier().verify(token(), 'nonce-abc')).rejects.toMatchObject(
      { code: 'AUTH_GOOGLE_INVALID' },
    );
  });

  it('AC-GA-07 req に nonce が無ければ token の nonce は検証しない', async () => {
    await expect(
      verifier().verify(token({ nonce: 'nonce-abc' })),
    ).resolves.toMatchObject({ sub: GOOGLE_SUB });
  });

  it('AC-GA-08 未知の kid（鍵が見つからない）は 401', async () => {
    await expect(
      verifier().verify(token({}, { kid: 'unknown-kid' })),
    ).rejects.toMatchObject({ code: 'AUTH_GOOGLE_INVALID' });
  });

  it('AC-GA-03 JWT の形をしていない文字列は 401', async () => {
    await expect(verifier().verify('not-a-jwt')).rejects.toMatchObject({
      code: 'AUTH_GOOGLE_INVALID',
    });
    expect(getPublicKey).not.toHaveBeenCalled();
  });

  it('AC-GA-10 GOOGLE_CLIENT_IDS 未設定なら aud 検証を素通しせず INTERNAL 500', async () => {
    const configured = verifier({ GOOGLE_CLIENT_IDS: undefined });

    await expect(configured.verify(token())).rejects.toMatchObject({
      code: 'INTERNAL',
    });
    await expect(statusOf(configured.verify(token()))).resolves.toBe(500);
  });

  it('AC-GA-10 GOOGLE_CLIENT_IDS が空白・カンマだけなら INTERNAL 500', async () => {
    const configured = verifier({ GOOGLE_CLIENT_IDS: ' , ' });

    await expect(configured.verify(token())).rejects.toMatchObject({
      code: 'INTERNAL',
    });
  });
});
