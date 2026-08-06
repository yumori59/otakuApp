import { sha256Hex } from '../common/util/hash.util';
import {
  RESET_CODE_MAX_ATTEMPTS,
  RESET_CODE_PATTERN,
  RESET_CODE_TTL_MINUTES,
  generateResetCode,
  resetCodeHash,
} from './reset-code.generator';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';

describe('reset-code.generator', () => {
  it('AC-PR-04 生成されるコードは常に 8 桁の数字（先頭 0 も許す）', () => {
    for (let i = 0; i < 200; i += 1) {
      expect(generateResetCode()).toMatch(/^\d{8}$/);
    }
  });

  it('AC-PR-04 コードは毎回同じ値にならない', () => {
    const codes = new Set(
      Array.from({ length: 50 }, () => generateResetCode()),
    );

    expect(codes.size).toBeGreaterThan(1);
  });

  it('AC-PR-04 codeHash は sha256(userId + ":" + code) で平文を含まない', () => {
    const hash = resetCodeHash(USER_ID, '04821093');

    expect(hash).toBe(sha256Hex(`${USER_ID}:04821093`));
    expect(hash).not.toContain('04821093');
  });

  it('AC-PR-09 ユーザーが違えば同じコードでもハッシュが異なる', () => {
    expect(resetCodeHash(USER_ID, '04821093')).not.toBe(
      resetCodeHash('018f3c2a-0000-7c90-9d2a-000000000002', '04821093'),
    );
  });

  it('TTL・試行回数はコード定数（plan.md §4.4）', () => {
    expect(RESET_CODE_TTL_MINUTES).toBe(15);
    expect(RESET_CODE_MAX_ATTEMPTS).toBe(5);
    expect(RESET_CODE_PATTERN.test('04821093')).toBe(true);
    expect(RESET_CODE_PATTERN.test('4821093')).toBe(false);
    expect(RESET_CODE_PATTERN.test('048210934')).toBe(false);
    expect(RESET_CODE_PATTERN.test('0482109a')).toBe(false);
  });
});
