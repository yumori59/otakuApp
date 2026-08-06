import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { generateKeyPairSync } from 'node:crypto';
import { FORCED_FETCH_COOLDOWN_MS } from './oidc/remote-jwks.provider';
import {
  DEFAULT_GOOGLE_JWKS_URL,
  RemoteGoogleJwksProvider,
} from './google-jwks.provider';

const KID = 'google-key-1';
const NOW = new Date('2026-08-01T00:00:00.000Z');

function configStub(url?: string): ConfigService {
  return {
    get: jest.fn(() => url),
  } as unknown as ConfigService;
}

function jwksBody(kid: string): { keys: unknown[] } {
  const { publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = publicKey.export({ format: 'jwk' }) as { n: string; e: string };
  return {
    keys: [{ kty: 'RSA', kid, alg: 'RS256', use: 'sig', n: jwk.n, e: jwk.e }],
  };
}

describe('RemoteGoogleJwksProvider', () => {
  let fetchMock: jest.Mock;
  let provider: RemoteGoogleJwksProvider;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
    fetchMock = jest.fn(() =>
      Promise.resolve({ ok: true, json: () => Promise.resolve(jwksBody(KID)) }),
    );
    global.fetch = fetchMock as unknown as typeof fetch;
    provider = new RemoteGoogleJwksProvider(configStub());
  });

  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('AC-GA-08 GOOGLE_JWKS_URL 未設定なら Google 既定の JWKS を引く', async () => {
    await provider.getPublicKey(KID);

    expect(fetchMock).toHaveBeenCalledWith(
      DEFAULT_GOOGLE_JWKS_URL,
      expect.anything(),
    );
  });

  it('AC-GA-08 GOOGLE_JWKS_URL が設定されていればそちらを引く', async () => {
    provider = new RemoteGoogleJwksProvider(
      configStub('https://example.test/certs'),
    );

    await provider.getPublicKey(KID);

    expect(fetchMock).toHaveBeenCalledWith(
      'https://example.test/certs',
      expect.anything(),
    );
  });

  it('AC-GA-08 既知の kid はキャッシュから解決し、2 回目は再取得しない', async () => {
    await expect(provider.getPublicKey(KID)).resolves.not.toBeNull();
    await expect(provider.getPublicKey(KID)).resolves.not.toBeNull();

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('AC-GA-08 未知 kid は 1 度だけ強制再取得し、cooldown 中は再取得しない', async () => {
    await expect(provider.getPublicKey('unknown-1')).resolves.toBeNull();
    expect(fetchMock).toHaveBeenCalledTimes(2);

    fetchMock.mockClear();
    for (let i = 0; i < 10; i += 1) {
      await expect(provider.getPublicKey(`unknown-${i}`)).resolves.toBeNull();
    }
    expect(fetchMock).not.toHaveBeenCalled();

    jest.setSystemTime(new Date(NOW.getTime() + FORCED_FETCH_COOLDOWN_MS));
    await expect(provider.getPublicKey('unknown-late')).resolves.toBeNull();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('AC-GA-08 JWKS 取得に失敗しても例外を投げず null を返す', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 503, json: jest.fn() });

    await expect(provider.getPublicKey(KID)).resolves.toBeNull();
  });
});
