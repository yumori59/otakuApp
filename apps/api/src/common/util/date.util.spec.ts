process.env.TZ = 'Asia/Tokyo';

import { AppError } from '../errors/app-error';
import { fromDateOnly, toDateOnly } from './date.util';

describe('date.util (TZ=Asia/Tokyo)', () => {
  it('AC-CORE-06 toDateOnly は UTC 0 時の Date にする', () => {
    expect(toDateOnly('2026-08-20').toISOString()).toBe(
      '2026-08-20T00:00:00.000Z',
    );
  });

  it('AC-CORE-06 fromDateOnly で往復一致する', () => {
    for (const s of ['2026-08-20', '2026-01-01', '2026-12-31', '2024-02-29']) {
      expect(fromDateOnly(toDateOnly(s))).toBe(s);
    }
  });

  it('AC-CORE-06 fromDateOnly(null) は null', () => {
    expect(fromDateOnly(null)).toBeNull();
    expect(fromDateOnly(undefined)).toBeNull();
  });

  it('AC-CORE-06 ローカル TZ が JST でも日付がずれない', () => {
    expect(new Date().getTimezoneOffset()).toBe(-540);
    expect(fromDateOnly(new Date('2026-08-20T00:00:00.000Z'))).toBe(
      '2026-08-20',
    );
    expect(fromDateOnly(new Date('2026-08-20T23:59:59.999Z'))).toBe(
      '2026-08-20',
    );
  });

  it('AC-CORE-06 不正な日付文字列は VALIDATION_ERROR', () => {
    for (const s of ['2026-8-20', '20260820', '2026-08-20T00:00:00Z', '']) {
      expect(() => toDateOnly(s)).toThrow(AppError);
      try {
        toDateOnly(s);
      } catch (e) {
        expect((e as AppError).code).toBe('VALIDATION_ERROR');
      }
    }
  });

  it('AC-CORE-06 存在しない日付は VALIDATION_ERROR', () => {
    expect(() => toDateOnly('2026-02-30')).toThrow(AppError);
  });
});
