import { ConfigService } from '@nestjs/config';
import { KeyObject, createSign, generateKeyPairSync } from 'node:crypto';
import { AppError } from '../common/errors/app-error';
import { AppleJwksProvider } from './apple-jwks.provider';
import { AppleIdentityTokenVerifier } from './apple-token.verifier';

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_CLIENT_ID = 'com.example.meigicho';
const APPLE_SUB = '001234.abcdef0123456789.0000';
const KID = 'test-key-1';

const ENV: Record<string, string> = {
  APPLE_CLIENT_ID,
  APPLE_ISSUER,
  APPLE_JWKS_URL: 'https://appleid.apple.com/auth/keys',
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

/** Apple の identity token を模した RS256 JWT をローカル鍵で生成する（外部通信しない）。 */
function signToken(options: {
  privateKey: KeyObject;
  payload: Record<string, unknown>;
  alg?: string;
  kid?: string | null;
  tamper?: boolean;
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

describe('AppleIdentityTokenVerifier', () => {
  let privateKey: KeyObject;
  let publicKey: KeyObject;
  let otherPrivateKey: KeyObject;
  let jwks: AppleJwksProvider;
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
    jwks = { getPublicKey } as unknown as AppleJwksProvider;
  });

  function verifier(configOverrides: Record<string, string | undefined> = {}) {
    return new AppleIdentityTokenVerifier(configStub(configOverrides), jwks);
  }

  function claims(overrides: Record<string, unknown> = {}) {
    const nowSeconds = Math.floor(Date.now() / 1000);
    return {
      iss: APPLE_ISSUER,
      aud: APPLE_CLIENT_ID,
      sub: APPLE_SUB,
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

  it('有効な identity token から sub と email を取り出す', async () => {
    await expect(
      verifier().verify(token({ email: 'abc@privaterelay.appleid.com' })),
    ).resolves.toEqual({
      sub: APPLE_SUB,
      email: 'abc@privaterelay.appleid.com',
    });
    expect(getPublicKey).toHaveBeenCalledWith(KID);
  });

  it('email を含まない token は email: null になる', async () => {
    await expect(verifier().verify(token())).resolves.toEqual({
      sub: APPLE_SUB,
      email: null,
    });
  });

  it('AC-AUTH-03 署名が不正なら AUTH_APPLE_INVALID 401', async () => {
    const forged = token({}, { privateKey: otherPrivateKey });

    await expect(verifier().verify(forged)).rejects.toMatchObject({
      code: 'AUTH_APPLE_INVALID',
    });
    await expect(verifier().verify(forged)).rejects.toBeInstanceOf(AppError);
    await expect(statusOf(verifier().verify(forged))).resolves.toBe(401);
  });

  it('AC-AUTH-03 aud が別アプリなら AUTH_APPLE_INVALID 401 (E-14)', async () => {
    await expect(
      verifier().verify(token({ aud: 'com.other.app' })),
    ).rejects.toMatchObject({ code: 'AUTH_APPLE_INVALID' });
  });

  it('AC-AUTH-03 aud 配列に自アプリが含まれなければ 401', async () => {
    await expect(
      verifier().verify(token({ aud: ['com.other.app'] })),
    ).rejects.toMatchObject({ code: 'AUTH_APPLE_INVALID' });
  });

  it('AC-AUTH-03 iss が Apple 以外なら AUTH_APPLE_INVALID 401', async () => {
    await expect(
      verifier().verify(token({ iss: 'https://evil.example.com' })),
    ).rejects.toMatchObject({ code: 'AUTH_APPLE_INVALID' });
  });

  it('AC-AUTH-03 exp 切れなら AUTH_APPLE_INVALID 401', async () => {
    const expired = token({ exp: Math.floor(Date.now() / 1000) - 1 });

    await expect(verifier().verify(expired)).rejects.toMatchObject({
      code: 'AUTH_APPLE_INVALID',
    });
  });

  it('AC-AUTH-03 exp が無い token は 401', async () => {
    const nowSeconds = Math.floor(Date.now() / 1000);
    const noExp = signToken({
      privateKey,
      payload: {
        iss: APPLE_ISSUER,
        aud: APPLE_CLIENT_ID,
        sub: APPLE_SUB,
        iat: nowSeconds,
      },
    });

    await expect(verifier().verify(noExp)).rejects.toMatchObject({
      code: 'AUTH_APPLE_INVALID',
    });
  });

  it('AC-AUTH-03 sub が無い token は 401', async () => {
    await expect(
      verifier().verify(token({ sub: undefined })),
    ).rejects.toMatchObject({ code: 'AUTH_APPLE_INVALID' });
  });

  it('AC-AUTH-03 alg: none への摩り替えは 401', async () => {
    const header = base64url(JSON.stringify({ alg: 'none', kid: KID }));
    const payload = base64url(JSON.stringify(claims()));

    await expect(
      verifier().verify(`${header}.${payload}.`),
    ).rejects.toMatchObject({ code: 'AUTH_APPLE_INVALID' });
  });

  it('AC-AUTH-03 RS256 以外の alg は 401', async () => {
    await expect(
      verifier().verify(token({}, { alg: 'HS256' })),
    ).rejects.toMatchObject({ code: 'AUTH_APPLE_INVALID' });
  });

  it('AC-AUTH-03 未知の kid（鍵が見つからない）は 401', async () => {
    await expect(
      verifier().verify(token({}, { kid: 'unknown-kid' })),
    ).rejects.toMatchObject({ code: 'AUTH_APPLE_INVALID' });
  });

  it('AC-AUTH-03 JWT の形をしていない文字列は 401', async () => {
    await expect(verifier().verify('not-a-jwt')).rejects.toMatchObject({
      code: 'AUTH_APPLE_INVALID',
    });
    expect(getPublicKey).not.toHaveBeenCalled();
  });

  it('AC-AUTH-04 req の nonce と token の nonce が一致すれば通る', async () => {
    await expect(
      verifier().verify(token({ nonce: 'nonce-abc' }), 'nonce-abc'),
    ).resolves.toMatchObject({ sub: APPLE_SUB });
  });

  it('AC-AUTH-04 req の nonce と token の nonce が不一致なら 401', async () => {
    await expect(
      verifier().verify(token({ nonce: 'nonce-abc' }), 'nonce-different'),
    ).rejects.toMatchObject({ code: 'AUTH_APPLE_INVALID' });
  });

  it('AC-AUTH-04 req に nonce があるのに token に nonce が無ければ 401', async () => {
    await expect(verifier().verify(token(), 'nonce-abc')).rejects.toMatchObject(
      { code: 'AUTH_APPLE_INVALID' },
    );
  });

  it('AC-AUTH-04 req に nonce が無ければ token の nonce は検証しない', async () => {
    await expect(
      verifier().verify(token({ nonce: 'nonce-abc' })),
    ).resolves.toMatchObject({ sub: APPLE_SUB });
  });

  it('APPLE_CLIENT_ID 未設定なら aud 検証を素通しせず INTERNAL 500 を投げる', async () => {
    const configured = verifier({ APPLE_CLIENT_ID: undefined });

    await expect(configured.verify(token())).rejects.toMatchObject({
      code: 'INTERNAL',
    });
    await expect(statusOf(configured.verify(token()))).resolves.toBe(500);
  });
});
