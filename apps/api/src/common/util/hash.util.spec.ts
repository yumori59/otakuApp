import { randomToken, sha256Hex } from './hash.util';

describe('hash.util', () => {
  it('sha256Hex は既知ベクタと一致する 64 桁 hex を返す', () => {
    expect(sha256Hex('abc')).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(sha256Hex('abc')).toMatch(/^[0-9a-f]{64}$/);
  });

  it('sha256Hex は同じ入力で安定し、異なる入力で異なる', () => {
    expect(sha256Hex('token-a')).toBe(sha256Hex('token-a'));
    expect(sha256Hex('token-a')).not.toBe(sha256Hex('token-b'));
  });

  it('randomToken は base64url 文字のみで毎回異なる', () => {
    const a = randomToken();
    const b = randomToken();
    expect(a).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(a).not.toBe(b);
    expect(randomToken(16).length).toBeLessThan(a.length);
  });
});
