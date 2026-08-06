import { ConfigService } from '@nestjs/config';
import { Logger } from '@nestjs/common';
import { generateKeyPairSync } from 'node:crypto';
import {
  FORCED_FETCH_COOLDOWN_MS,
  RemoteAppleJwksProvider,
} from './apple-jwks.provider';

const KID = 'apple-key-1';
const NOW = new Date('2026-08-01T00:00:00.000Z');

function configStub(): ConfigService {
  return {
    get: jest.fn(() => 'https://appleid.apple.com/auth/keys'),
  } as unknown as ConfigService;
}

function jwksBody(kid: string): { keys: unknown[] } {
  const { publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = publicKey.export({ format: 'jwk' }) as { n: string; e: string };
  return {
    keys: [{ kty: 'RSA', kid, alg: 'RS256', use: 'sig', n: jwk.n, e: jwk.e }],
  };
}

describe('RemoteAppleJwksProvider', () => {
  let fetchMock: jest.Mock;
  let provider: RemoteAppleJwksProvider;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
    fetchMock = jest.fn(() =>
      Promise.resolve({ ok: true, json: () => Promise.resolve(jwksBody(KID)) }),
    );
    global.fetch = fetchMock as unknown as typeof fetch;
    provider = new RemoteAppleJwksProvider(configStub());
  });

  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('既知の kid はキャッシュから解決し、2 回目は再取得しない', async () => {
    await expect(provider.getPublicKey(KID)).resolves.not.toBeNull();
    await expect(provider.getPublicKey(KID)).resolves.not.toBeNull();

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('未知 kid は 1 度だけ強制再取得する（鍵ローテーション対応）', async () => {
    await expect(provider.getPublicKey('unknown-kid')).resolves.toBeNull();

    // 初回キャッシュ構築 + 強制再取得の 2 回
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it('中-1 cooldown 中の未知 kid は再取得せず null を返す（未認証 DoS 面を塞ぐ）', async () => {
    await provider.getPublicKey('unknown-1');
    fetchMock.mockClear();

    for (let i = 0; i < 20; i += 1) {
      await expect(provider.getPublicKey(`unknown-${i}`)).resolves.toBeNull();
    }

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('中-1 cooldown 経過後は未知 kid で再び強制再取得する', async () => {
    await provider.getPublicKey('unknown-1');
    fetchMock.mockClear();

    jest.setSystemTime(new Date(NOW.getTime() + FORCED_FETCH_COOLDOWN_MS));
    await expect(provider.getPublicKey('unknown-2')).resolves.toBeNull();

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('中-1 cooldown 中でもローテーション後の既知 kid はキャッシュから解決できる', async () => {
    await provider.getPublicKey('unknown-1');
    fetchMock.mockClear();

    await expect(provider.getPublicKey(KID)).resolves.not.toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('JWKS 取得に失敗しても例外を投げず null を返す', async () => {
    fetchMock.mockResolvedValue({ ok: false, status: 503, json: jest.fn() });

    await expect(provider.getPublicKey(KID)).resolves.toBeNull();
  });
});
