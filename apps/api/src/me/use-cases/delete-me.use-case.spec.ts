import { Logger } from '@nestjs/common';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AppleTokenRevoker } from '../../auth/apple-token.revoker';
import { PasswordHasher } from '../../auth/password.hasher';
import { MeService } from '../me.service';
import { DeleteMeUseCase } from './delete-me.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const PASSWORD = 'correct horse battery';
const APPLE_CODE = 'c1a2b3-authorization-code';
const STORED_HASH = 'scrypt$32768$8$3$salt$hash';

function userRow(overrides: Record<string, unknown> = {}) {
  return {
    id: USER_ID,
    passwordHash: null as string | null,
    appleSub: null as string | null,
    ...overrides,
  };
}

/** 例外に載った全文字列（message / response / stack）を 1 本にまとめる（AC-AD-13）。 */
function serializeError(error: unknown): string {
  const parts: string[] = [String(error)];
  if (error instanceof Error) {
    parts.push(error.message, error.stack ?? '');
  }
  if (error instanceof AppError) {
    parts.push(JSON.stringify(error.getResponse()));
  }
  return parts.join('\n');
}

describe('DeleteMeUseCase', () => {
  let meService: {
    findUserForDeletion: jest.Mock;
    deleteAccount: jest.Mock;
  };
  let hasher: { verify: jest.Mock; hash: jest.Mock; needsRehash: jest.Mock };
  let revoker: { revokeAuthorizationCode: jest.Mock };
  let logged: string[];
  let useCase: DeleteMeUseCase;

  beforeEach(() => {
    meService = {
      findUserForDeletion: jest.fn().mockResolvedValue(userRow()),
      deleteAccount: jest.fn().mockResolvedValue(undefined),
    };
    hasher = {
      verify: jest.fn().mockResolvedValue(true),
      hash: jest.fn(),
      needsRehash: jest.fn().mockReturnValue(false),
    };
    revoker = { revokeAuthorizationCode: jest.fn().mockResolvedValue(undefined) };

    logged = [];
    const record = (...args: unknown[]) => {
      logged.push(args.map((a) => String(a)).join(' '));
      return undefined;
    };
    for (const level of ['log', 'warn', 'error', 'debug', 'verbose'] as const) {
      jest.spyOn(Logger.prototype, level).mockImplementation(record);
    }

    useCase = new DeleteMeUseCase(
      meService as unknown as MeService,
      hasher as unknown as PasswordHasher,
      revoker as unknown as AppleTokenRevoker,
    );
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('AC-AD-01 password_hash が null なら password 無しで削除する', async () => {
    meService.findUserForDeletion.mockResolvedValue(
      userRow({ passwordHash: null, appleSub: 'apple-sub-1' }),
    );

    await expect(useCase.execute(USER_ID, {})).resolves.toBeUndefined();

    expect(hasher.verify).not.toHaveBeenCalled();
    expect(meService.deleteAccount).toHaveBeenCalledWith(USER_ID);
  });

  it('E-11 password_hash が null のユーザーが password を送っても無視して削除する（400 にしない）', async () => {
    meService.findUserForDeletion.mockResolvedValue(
      userRow({ passwordHash: null }),
    );

    await expect(
      useCase.execute(USER_ID, { password: PASSWORD }),
    ).resolves.toBeUndefined();

    expect(hasher.verify).not.toHaveBeenCalled();
    expect(meService.deleteAccount).toHaveBeenCalledWith(USER_ID);
  });

  it('AC-AD-02 password_hash があり password 未指定なら VALIDATION_ERROR で削除しない', async () => {
    meService.findUserForDeletion.mockResolvedValue(
      userRow({ passwordHash: STORED_HASH }),
    );

    const error = await useCase.execute(USER_ID, {}).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(AppError);
    expect((error as AppError).code).toBe(ErrorCode.VALIDATION_ERROR);
    expect((error as AppError).getStatus()).toBe(400);
    expect(meService.deleteAccount).not.toHaveBeenCalled();
  });

  it('AC-AD-03 password 不一致なら AUTH_CREDENTIALS_INVALID で削除しない', async () => {
    meService.findUserForDeletion.mockResolvedValue(
      userRow({ passwordHash: STORED_HASH }),
    );
    hasher.verify.mockResolvedValue(false);

    const error = await useCase
      .execute(USER_ID, { password: 'wrong password' })
      .catch((e: unknown) => e);

    expect(error).toBeInstanceOf(AppError);
    expect((error as AppError).code).toBe(ErrorCode.AUTH_CREDENTIALS_INVALID);
    expect((error as AppError).getStatus()).toBe(401);
    // POST /v1/auth/password と同じ固定メッセージ（契約 §0）
    expect((error as AppError).message).toBe('invalid email or password');
    expect(meService.deleteAccount).not.toHaveBeenCalled();
  });

  it('AC-AD-04 password 一致なら削除する', async () => {
    meService.findUserForDeletion.mockResolvedValue(
      userRow({ passwordHash: STORED_HASH }),
    );

    await expect(
      useCase.execute(USER_ID, { password: PASSWORD }),
    ).resolves.toBeUndefined();

    expect(hasher.verify).toHaveBeenCalledWith(PASSWORD, STORED_HASH);
    expect(meService.deleteAccount).toHaveBeenCalledWith(USER_ID);
  });

  it('AC-AD-07 対象ユーザーが存在しなければ NOT_FOUND 404 で削除しない', async () => {
    meService.findUserForDeletion.mockResolvedValue(null);

    const error = await useCase
      .execute(USER_ID, { password: PASSWORD })
      .catch((e: unknown) => e);

    expect(error).toBeInstanceOf(AppError);
    expect((error as AppError).code).toBe(ErrorCode.NOT_FOUND);
    expect((error as AppError).getStatus()).toBe(404);
    expect((error as AppError).message).toBe('user not found');
    expect(meService.deleteAccount).not.toHaveBeenCalled();
  });

  it('E-1 並行削除で Service が NOT_FOUND を投げたらそのまま伝播する', async () => {
    meService.deleteAccount.mockRejectedValue(
      AppError.notFound('user not found'),
    );

    const error = await useCase.execute(USER_ID, {}).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(AppError);
    expect((error as AppError).code).toBe(ErrorCode.NOT_FOUND);
  });

  it('BE-4 削除対象は常に引数の userId（ボディで対象を指定できない）', async () => {
    await useCase.execute(USER_ID, {
      password: PASSWORD,
      apple_authorization_code: APPLE_CODE,
    });

    expect(meService.findUserForDeletion).toHaveBeenCalledWith(USER_ID);
    expect(meService.deleteAccount).toHaveBeenCalledTimes(1);
    expect(meService.deleteAccount).toHaveBeenCalledWith(USER_ID);
  });

  it('契約 §1 apple_authorization_code は削除結果（204）に影響しない', async () => {
    await expect(
      useCase.execute(USER_ID, { apple_authorization_code: APPLE_CODE }),
    ).resolves.toBeUndefined();

    expect(meService.deleteAccount).toHaveBeenCalledWith(USER_ID);
  });

  describe('Apple トークン失効（T-BE2 / FR-AD-11 / D3）', () => {
    it('AC-AD-11 apple_authorization_code があれば削除成功後に失効を呼ぶ', async () => {
      const order: string[] = [];
      meService.deleteAccount.mockImplementation(() => {
        order.push('delete');
        return Promise.resolve();
      });
      revoker.revokeAuthorizationCode.mockImplementation(() => {
        order.push('revoke');
        return Promise.resolve();
      });

      await useCase.execute(USER_ID, { apple_authorization_code: APPLE_CODE });

      expect(revoker.revokeAuthorizationCode).toHaveBeenCalledWith(APPLE_CODE);
      expect(order).toEqual(['delete', 'revoke']);
    });

    it('apple_authorization_code が無ければ失効を呼ばない', async () => {
      await useCase.execute(USER_ID, {});

      expect(revoker.revokeAuthorizationCode).not.toHaveBeenCalled();
    });

    it('AC-AD-12 失効が例外を投げても削除は成功扱い（204）', async () => {
      revoker.revokeAuthorizationCode.mockRejectedValue(
        new Error('apple revoke failed'),
      );

      await expect(
        useCase.execute(USER_ID, { apple_authorization_code: APPLE_CODE }),
      ).resolves.toBeUndefined();

      expect(meService.deleteAccount).toHaveBeenCalledWith(USER_ID);
    });

    it('E-7 削除自体が失敗したときは失効を呼ばない', async () => {
      meService.deleteAccount.mockRejectedValue(new Error('transaction failed'));

      await expect(
        useCase.execute(USER_ID, { apple_authorization_code: APPLE_CODE }),
      ).rejects.toBeInstanceOf(Error);

      expect(revoker.revokeAuthorizationCode).not.toHaveBeenCalled();
    });

    it('NFR-AD-3 失効失敗の warn に apple_authorization_code を含めない', async () => {
      revoker.revokeAuthorizationCode.mockRejectedValue(
        new Error(`revoke failed for ${APPLE_CODE}`),
      );

      await useCase.execute(USER_ID, { apple_authorization_code: APPLE_CODE });

      expect(logged.join('\n')).not.toContain(APPLE_CODE);
    });
  });

  it('AC-AD-13 例外に password / apple_authorization_code の値が含まれない', async () => {
    meService.findUserForDeletion.mockResolvedValue(
      userRow({ passwordHash: STORED_HASH }),
    );
    hasher.verify.mockResolvedValue(false);

    const mismatch = await useCase
      .execute(USER_ID, {
        password: PASSWORD,
        apple_authorization_code: APPLE_CODE,
      })
      .catch((e: unknown) => e);

    meService.findUserForDeletion.mockResolvedValue(
      userRow({ passwordHash: STORED_HASH }),
    );
    const missing = await useCase
      .execute(USER_ID, { apple_authorization_code: APPLE_CODE })
      .catch((e: unknown) => e);

    for (const error of [mismatch, missing]) {
      const dumped = serializeError(error);
      expect(dumped).not.toContain(PASSWORD);
      expect(dumped).not.toContain(APPLE_CODE);
    }
  });

  it('AC-AD-13 例外メッセージに password の値が含まれない（Service 失敗時も同様）', async () => {
    meService.findUserForDeletion.mockResolvedValue(
      userRow({ passwordHash: STORED_HASH }),
    );
    meService.deleteAccount.mockRejectedValue(new Error('transaction timeout'));

    const error = await useCase
      .execute(USER_ID, { password: PASSWORD })
      .catch((e: unknown) => e);

    expect(serializeError(error)).not.toContain(PASSWORD);
  });
});
