import {
  daysUntilDateOnly,
  daysUntilRenewal,
  renewalUrgency,
  todayJstDateString,
} from './renewal.util';

describe('renewal.util', () => {
  it('todayJstDateString は JST 基準の YYYY-MM-DD', () => {
    jest.useFakeTimers().setSystemTime(new Date('2026-08-01T15:00:00.000Z'));
    expect(todayJstDateString()).toBe('2026-08-02');
    jest.useRealTimers();
  });

  it('daysUntilDateOnly は日付差を返す', () => {
    expect(daysUntilDateOnly('2026-08-01', '2026-08-15')).toBe(14);
  });

  it('daysUntilRenewal は renewal_on から JST 今日までの日数', () => {
    const days = daysUntilRenewal(
      new Date('2026-09-15T00:00:00.000Z'),
      '2026-07-31',
    );
    expect(days).toBe(46);
  });

  it('renewalUrgency は docs/03 §7.2 と同一', () => {
    expect(renewalUrgency(-1)).toBe('expired');
    expect(renewalUrgency(0)).toBe('warning');
    expect(renewalUrgency(14)).toBe('warning');
    expect(renewalUrgency(15)).toBe('soon');
    expect(renewalUrgency(30)).toBe('soon');
    expect(renewalUrgency(31)).toBe('ok');
  });
});
