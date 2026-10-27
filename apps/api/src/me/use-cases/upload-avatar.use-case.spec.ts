import sharp from 'sharp';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AvatarImageProcessor } from '../avatar/avatar-image.processor';
import { AvatarService } from '../avatar/avatar.service';
import { AvatarStorage } from '../avatar/avatar.storage';
import { MeService } from '../me.service';
import { UploadAvatarUseCase } from './upload-avatar.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';

async function makeJpegFile(): Promise<Express.Multer.File> {
  const buffer = await sharp({
    create: { width: 1000, height: 600, channels: 3, background: { r: 200, g: 100, b: 50 } },
  })
    .jpeg()
    .toBuffer();
  return { buffer, originalname: 'test.jpg', mimetype: 'image/jpeg' } as Express.Multer.File;
}

const ME_VIEW = { user: {}, profile: { avatar_url: 'https://example.com/new.jpg' }, entitlement: {} };

describe('UploadAvatarUseCase', () => {
  let processor: { process: jest.Mock };
  let storage: { isConfigured: jest.Mock; put: jest.Mock; delete: jest.Mock; publicUrl: jest.Mock };
  let avatarService: { findObjectKeyOrUnavailable: jest.Mock; replace: jest.Mock };
  let meService: { getMe: jest.Mock };
  let useCase: UploadAvatarUseCase;

  beforeEach(() => {
    processor = { process: jest.fn().mockResolvedValue(Buffer.from([0xff, 0xd8, 0xff])) };
    storage = {
      isConfigured: jest.fn().mockReturnValue(true),
      put: jest.fn().mockResolvedValue(undefined),
      delete: jest.fn().mockResolvedValue(undefined),
      publicUrl: jest.fn().mockReturnValue('https://example.com/new.jpg'),
    };
    avatarService = {
      findObjectKeyOrUnavailable: jest.fn().mockResolvedValue(null),
      replace: jest.fn().mockResolvedValue({ previousKey: null }),
    };
    meService = { getMe: jest.fn().mockResolvedValue(ME_VIEW) };
    useCase = new UploadAvatarUseCase(
      processor as unknown as AvatarImageProcessor,
      storage as unknown as AvatarStorage,
      avatarService as unknown as AvatarService,
      meService as unknown as MeService,
    );
  });

  it('AC-AV-04 正常: processor の出力が storage.put に渡され MeView を返す', async () => {
    const file = await makeJpegFile();
    const result = await useCase.execute(USER_ID, file);

    expect(processor.process).toHaveBeenCalledWith(file.buffer);
    expect(storage.put).toHaveBeenCalledWith(
      expect.stringMatching(/^avatars\/[0-9a-f-]{36}\.jpg$/),
      expect.any(Buffer),
    );
    expect(result).toBe(ME_VIEW);
  });

  it('AC-AV-04 キーが avatars/<UUID v4>.jpg の形式で userId を含まない', async () => {
    const file = await makeJpegFile();
    await useCase.execute(USER_ID, file);

    const [key] = storage.put.mock.calls[0] as [string, Buffer];
    expect(key).toMatch(/^avatars\/[0-9a-f-]{36}\.jpg$/);
    expect(key).not.toContain(USER_ID);
  });

  it('AC-AV-09 file が undefined → VALIDATION_ERROR "file is required"', async () => {
    const err = await useCase.execute(USER_ID, undefined).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(AppError);
    expect((err as AppError).code).toBe(ErrorCode.VALIDATION_ERROR);
    expect((err as AppError).message).toBe('file is required');
    expect(storage.put).not.toHaveBeenCalled();
  });

  it('AC-AV-13 isConfigured() === false → SERVICE_UNAVAILABLE、processor/service/storage 未呼び出し', async () => {
    storage.isConfigured.mockReturnValue(false);
    const file = await makeJpegFile();

    const err = await useCase.execute(USER_ID, file).catch((e: unknown) => e);

    expect(err).toBeInstanceOf(AppError);
    expect((err as AppError).code).toBe(ErrorCode.SERVICE_UNAVAILABLE);
    expect(processor.process).not.toHaveBeenCalled();
    expect(storage.put).not.toHaveBeenCalled();
    expect(avatarService.findObjectKeyOrUnavailable).not.toHaveBeenCalled();
  });

  it('AC-AV-18 findObjectKeyOrUnavailable が SERVICE_UNAVAILABLE → put 前に 503（アップロードしない）', async () => {
    avatarService.findObjectKeyOrUnavailable.mockRejectedValue(
      new AppError(ErrorCode.SERVICE_UNAVAILABLE, 'avatar is temporarily unavailable'),
    );
    const file = await makeJpegFile();

    const err = await useCase.execute(USER_ID, file).catch((e: unknown) => e);

    expect(err).toBeInstanceOf(AppError);
    expect((err as AppError).code).toBe(ErrorCode.SERVICE_UNAVAILABLE);
    expect(storage.put).not.toHaveBeenCalled();
  });

  it('AC-AV-11 previousKey あり → replace の後に delete(previousKey) を呼ぶ', async () => {
    const previousKey = 'avatars/old-key.jpg';
    avatarService.replace.mockResolvedValue({ previousKey });

    const order: string[] = [];
    avatarService.replace.mockImplementation(() => {
      order.push('replace');
      return Promise.resolve({ previousKey });
    });
    storage.delete.mockImplementation(() => {
      order.push('delete');
      return Promise.resolve();
    });

    const file = await makeJpegFile();
    await useCase.execute(USER_ID, file);

    expect(storage.delete).toHaveBeenCalledWith(previousKey);
    expect(order[0]).toBe('replace');
    expect(order[1]).toBe('delete');
  });

  it('AC-AV-11 delete(previousKey) が reject しても MeView を返す', async () => {
    avatarService.replace.mockResolvedValue({ previousKey: 'avatars/old-key.jpg' });
    storage.delete.mockRejectedValue(new Error('storage error'));

    const file = await makeJpegFile();
    const result = await useCase.execute(USER_ID, file);

    expect(result).toBe(ME_VIEW);
  });

  it('AC-AV-12 replace が reject → delete(newKey) を呼び、元の例外を再スロー', async () => {
    const replaceError = new AppError(ErrorCode.NOT_FOUND, 'user not found');
    avatarService.replace.mockRejectedValue(replaceError);

    const file = await makeJpegFile();
    const err = await useCase.execute(USER_ID, file).catch((e: unknown) => e);

    expect(err).toBe(replaceError);
    // 新しいキーに対して補償削除が呼ばれた
    expect(storage.delete).toHaveBeenCalledWith(
      expect.stringMatching(/^avatars\/[0-9a-f-]{36}\.jpg$/),
    );
  });
});
