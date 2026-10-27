import { Prisma } from '@prisma/client';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { PrismaService } from '../../prisma/prisma.service';
import { AvatarStorage } from './avatar.storage';
import { AvatarService } from './avatar.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const KEY = 'avatars/abc123.jpg';
const BASE_URL = 'https://storage.googleapis.com/test-avatars';

function p2021(): Prisma.PrismaClientKnownRequestError {
  return new Prisma.PrismaClientKnownRequestError(
    'The table `public.user_avatars` does not exist in the current database.',
    { code: 'P2021', clientVersion: '6.19.0' },
  );
}

function p2003(): Prisma.PrismaClientKnownRequestError {
  return new Prisma.PrismaClientKnownRequestError(
    'Foreign key constraint failed on the field: `user_id`',
    { code: 'P2003', clientVersion: '6.19.0' },
  );
}

function makeStorage(configured = true): AvatarStorage {
  return {
    isConfigured: jest.fn().mockReturnValue(configured),
    put: jest.fn().mockResolvedValue(undefined),
    delete: jest.fn().mockResolvedValue(undefined),
    publicUrl: jest.fn().mockImplementation((key: string) =>
      configured ? `${BASE_URL}/${key}` : null,
    ),
  } as unknown as AvatarStorage;
}

describe('AvatarService', () => {
  let prisma: {
    userAvatar: {
      findUnique: jest.Mock;
      upsert: jest.Mock;
      delete: jest.Mock;
    };
    $transaction: jest.Mock;
  };
  let storage: AvatarStorage;
  let service: AvatarService;

  beforeEach(() => {
    prisma = {
      userAvatar: {
        findUnique: jest.fn(),
        upsert: jest.fn().mockResolvedValue({}),
        delete: jest.fn().mockResolvedValue({}),
      },
      $transaction: jest.fn(),
    };
    // デフォルトで $transaction はコールバックを実行する
    prisma.$transaction.mockImplementation(
      (fn: (tx: typeof prisma) => Promise<unknown>) => fn(prisma),
    );
    storage = makeStorage();
    service = new AvatarService(
      prisma as unknown as PrismaService,
      storage,
    );
  });

  describe('findObjectKey', () => {
    it('AC-AV-01 行あり → objectKey を返す', async () => {
      prisma.userAvatar.findUnique.mockResolvedValue({ objectKey: KEY });
      expect(await service.findObjectKey(USER_ID)).toBe(KEY);
    });

    it('AC-AV-01 行なし → null', async () => {
      prisma.userAvatar.findUnique.mockResolvedValue(null);
      expect(await service.findObjectKey(USER_ID)).toBeNull();
    });

    it('AC-AV-03 P2021 → null（ログを出す、例外にしない）', async () => {
      prisma.userAvatar.findUnique.mockRejectedValue(p2021());
      const result = await service.findObjectKey(USER_ID);
      expect(result).toBeNull();
    });
  });

  describe('findObjectKeyOrUnavailable', () => {
    it('行あり → objectKey を返す', async () => {
      prisma.userAvatar.findUnique.mockResolvedValue({ objectKey: KEY });
      expect(await service.findObjectKeyOrUnavailable(USER_ID)).toBe(KEY);
    });

    it('AC-AV-18 P2021 → SERVICE_UNAVAILABLE', async () => {
      prisma.userAvatar.findUnique.mockRejectedValue(p2021());
      const err = await service
        .findObjectKeyOrUnavailable(USER_ID)
        .catch((e: unknown) => e);
      expect(err).toBeInstanceOf(AppError);
      expect((err as AppError).code).toBe(ErrorCode.SERVICE_UNAVAILABLE);
    });
  });

  describe('replace', () => {
    it('AC-AV-02 既存行あり → 前のキーを返す', async () => {
      prisma.userAvatar.findUnique.mockResolvedValue({ objectKey: 'old-key.jpg' });
      const result = await service.replace(USER_ID, KEY);
      expect(result.previousKey).toBe('old-key.jpg');
    });

    it('行なし → previousKey: null', async () => {
      prisma.userAvatar.findUnique.mockResolvedValue(null);
      const result = await service.replace(USER_ID, KEY);
      expect(result.previousKey).toBeNull();
    });

    it('AC-AV-18 P2021 → SERVICE_UNAVAILABLE', async () => {
      prisma.$transaction.mockRejectedValue(p2021());
      const err = await service.replace(USER_ID, KEY).catch((e: unknown) => e);
      expect(err).toBeInstanceOf(AppError);
      expect((err as AppError).code).toBe(ErrorCode.SERVICE_UNAVAILABLE);
    });

    it('E-3 P2003 → NOT_FOUND', async () => {
      prisma.$transaction.mockRejectedValue(p2003());
      const err = await service.replace(USER_ID, KEY).catch((e: unknown) => e);
      expect(err).toBeInstanceOf(AppError);
      expect((err as AppError).code).toBe(ErrorCode.NOT_FOUND);
    });
  });

  describe('remove', () => {
    it('AC-AV-14 行あり → previousKey を返す', async () => {
      prisma.userAvatar.findUnique.mockResolvedValue({ objectKey: KEY });
      const result = await service.remove(USER_ID);
      expect(result.previousKey).toBe(KEY);
      expect(prisma.userAvatar.delete).toHaveBeenCalledWith({ where: { userId: USER_ID } });
    });

    it('行なし → previousKey: null、delete を呼ばない', async () => {
      prisma.userAvatar.findUnique.mockResolvedValue(null);
      const result = await service.remove(USER_ID);
      expect(result.previousKey).toBeNull();
      expect(prisma.userAvatar.delete).not.toHaveBeenCalled();
    });

    it('AC-AV-18 P2021 → SERVICE_UNAVAILABLE', async () => {
      prisma.userAvatar.findUnique.mockRejectedValue(p2021());
      const err = await service.remove(USER_ID).catch((e: unknown) => e);
      expect(err).toBeInstanceOf(AppError);
      expect((err as AppError).code).toBe(ErrorCode.SERVICE_UNAVAILABLE);
    });
  });

  describe('avatarUrl', () => {
    it('AC-AV-02 行あり → storage.publicUrl の戻り値を返す', async () => {
      prisma.userAvatar.findUnique.mockResolvedValue({ objectKey: KEY });
      const url = await service.avatarUrl(USER_ID);
      expect(url).toBe(`${BASE_URL}/${KEY}`);
    });

    it('AC-AV-01 行なし → null', async () => {
      prisma.userAvatar.findUnique.mockResolvedValue(null);
      expect(await service.avatarUrl(USER_ID)).toBeNull();
    });

    it('AC-AV-03 P2021 → null（SERVICE_UNAVAILABLE にしない）', async () => {
      prisma.userAvatar.findUnique.mockRejectedValue(p2021());
      expect(await service.avatarUrl(USER_ID)).toBeNull();
    });
  });
});
