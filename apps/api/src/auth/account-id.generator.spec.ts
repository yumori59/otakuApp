import { AppError } from '../common/errors/app-error';
import {
  ACCOUNT_ID_MAX_ATTEMPTS,
  ACCOUNT_ID_PATTERN,
  AccountIdGenerator,
} from './account-id.generator';

/** Prisma のユニーク制約違反 (P2002) を模した例外。 */
function uniqueViolation(target: string[] = ['account_id']) {
  return Object.assign(new Error('Unique constraint failed'), {
    code: 'P2002',
    meta: { target },
  });
}

describe('AccountIdGenerator', () => {
  const generator = new AccountIdGenerator();

  it('AC-AUTH-10 account_id は ^ACC-[0-9A-F]{6}$ に一致する', () => {
    for (let i = 0; i < 200; i += 1) {
      const accountId = generator.generate();
      expect(accountId).toMatch(/^ACC-[0-9A-F]{6}$/);
      expect(ACCOUNT_ID_PATTERN.test(accountId)).toBe(true);
    }
  });

  it('AC-AUTH-10 衝突しなければ 1 回で確定する', async () => {
    const persist = jest.fn().mockResolvedValue('created');

    await expect(generator.issue(persist)).resolves.toBe('created');
    expect(persist).toHaveBeenCalledTimes(1);
    expect(persist.mock.calls[0][0]).toMatch(ACCOUNT_ID_PATTERN);
  });

  it('AC-AUTH-10 account_id のユニーク制約違反なら別の値で再試行する', async () => {
    const persist = jest
      .fn()
      .mockRejectedValueOnce(uniqueViolation())
      .mockRejectedValueOnce(uniqueViolation())
      .mockResolvedValue('created');

    await expect(generator.issue(persist)).resolves.toBe('created');
    expect(persist).toHaveBeenCalledTimes(3);

    const used = persist.mock.calls.map((call) => call[0] as string);
    used.forEach((accountId) => expect(accountId).toMatch(ACCOUNT_ID_PATTERN));
    expect(new Set(used).size).toBe(3);
  });

  it('AC-AUTH-10 最大5回まで再試行し、それでも衝突なら INTERNAL 500 (E-15)', async () => {
    const persist = jest.fn().mockRejectedValue(uniqueViolation());

    await expect(generator.issue(persist)).rejects.toMatchObject({
      code: 'INTERNAL',
    });
    expect(persist).toHaveBeenCalledTimes(ACCOUNT_ID_MAX_ATTEMPTS);
    expect(ACCOUNT_ID_MAX_ATTEMPTS).toBe(5);

    persist.mockClear();
    persist.mockRejectedValue(uniqueViolation());
    await expect(generator.issue(persist)).rejects.toBeInstanceOf(AppError);
  });

  it('account_id 以外のユニーク制約違反は再試行せずそのまま送出する', async () => {
    const error = uniqueViolation(['apple_sub']);
    const persist = jest.fn().mockRejectedValue(error);

    await expect(generator.issue(persist)).rejects.toBe(error);
    expect(persist).toHaveBeenCalledTimes(1);
  });

  it('ユニーク制約違反以外の例外は再試行せずそのまま送出する', async () => {
    const error = new Error('connection lost');
    const persist = jest.fn().mockRejectedValue(error);

    await expect(generator.issue(persist)).rejects.toBe(error);
    expect(persist).toHaveBeenCalledTimes(1);
  });
});
