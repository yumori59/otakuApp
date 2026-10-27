import { ConfigService } from '@nestjs/config';
import { GcsAvatarStorage } from './gcs-avatar.storage';

const BUCKET = 'test-avatars';
const KEY = 'avatars/abc123.jpg';
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0]);

// @google-cloud/storage のモック
const mockSave = jest.fn().mockResolvedValue(undefined);
const mockDelete = jest.fn().mockResolvedValue(undefined);
const mockFile = jest.fn().mockReturnValue({ save: mockSave, delete: mockDelete });
const mockBucket = jest.fn().mockReturnValue({ file: mockFile });

jest.mock('@google-cloud/storage', () => ({
  Storage: jest.fn().mockImplementation(() => ({ bucket: mockBucket })),
}));

function makeConfig(env: Record<string, string>): ConfigService {
  return {
    get: (key: string) => env[key] ?? '',
  } as unknown as ConfigService;
}

describe('GcsAvatarStorage', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    // Storage コンストラクタ mock をリセット
    const { Storage } = jest.requireMock<{
      Storage: jest.Mock;
    }>('@google-cloud/storage');
    Storage.mockImplementation(() => ({ bucket: mockBucket }));
  });

  describe('isConfigured', () => {
    it('E-10 AVATAR_BUCKET が空なら false', () => {
      const storage = new GcsAvatarStorage(makeConfig({ AVATAR_BUCKET: '' }));
      expect(storage.isConfigured()).toBe(false);
    });

    it('AVATAR_BUCKET が設定されていれば true', () => {
      const storage = new GcsAvatarStorage(makeConfig({ AVATAR_BUCKET: BUCKET }));
      expect(storage.isConfigured()).toBe(true);
    });
  });

  describe('publicUrl', () => {
    it('E-10 AVATAR_BUCKET が空なら null', () => {
      const storage = new GcsAvatarStorage(makeConfig({ AVATAR_BUCKET: '' }));
      expect(storage.publicUrl(KEY)).toBeNull();
    });

    it('AVATAR_PUBLIC_BASE_URL + "/" + objectKey を返す', () => {
      const storage = new GcsAvatarStorage(
        makeConfig({
          AVATAR_BUCKET: BUCKET,
          AVATAR_PUBLIC_BASE_URL: 'http://localhost:4443/test-avatars',
        }),
      );
      expect(storage.publicUrl(KEY)).toBe(`http://localhost:4443/test-avatars/${KEY}`);
    });

    it('E-10 AVATAR_PUBLIC_BASE_URL 空 → https://storage.googleapis.com/<bucket>/<key>', () => {
      const storage = new GcsAvatarStorage(
        makeConfig({ AVATAR_BUCKET: BUCKET, AVATAR_PUBLIC_BASE_URL: '' }),
      );
      expect(storage.publicUrl(KEY)).toBe(
        `https://storage.googleapis.com/${BUCKET}/${KEY}`,
      );
    });
  });

  describe('put', () => {
    it('AC-AV-04 contentType: image/jpeg と cacheControl: private, max-age=31536000, immutable で保存する', async () => {
      const storage = new GcsAvatarStorage(makeConfig({ AVATAR_BUCKET: BUCKET }));
      await storage.put(KEY, JPEG);

      expect(mockFile).toHaveBeenCalledWith(KEY);
      expect(mockSave).toHaveBeenCalledWith(JPEG, {
        contentType: 'image/jpeg',
        metadata: { cacheControl: 'private, max-age=31536000, immutable' },
        resumable: false,
      });
    });

    it('AVATAR_BUCKET 未設定のとき何もしない', async () => {
      const storage = new GcsAvatarStorage(makeConfig({ AVATAR_BUCKET: '' }));
      await storage.put(KEY, JPEG);
      expect(mockSave).not.toHaveBeenCalled();
    });
  });

  describe('delete', () => {
    it('正常ケースで GCS の delete を呼ぶ', async () => {
      const storage = new GcsAvatarStorage(makeConfig({ AVATAR_BUCKET: BUCKET }));
      await storage.delete(KEY);
      expect(mockDelete).toHaveBeenCalled();
    });

    it('404 は成功扱い（握り潰す）', async () => {
      mockDelete.mockRejectedValueOnce(
        Object.assign(new Error('No such object: test'), { code: 404 }),
      );
      const storage = new GcsAvatarStorage(makeConfig({ AVATAR_BUCKET: BUCKET }));
      await expect(storage.delete(KEY)).resolves.toBeUndefined();
    });

    it('404 以外のエラーは再スロー', async () => {
      const err = Object.assign(new Error('network error'), { code: 500 });
      mockDelete.mockRejectedValueOnce(err);
      const storage = new GcsAvatarStorage(makeConfig({ AVATAR_BUCKET: BUCKET }));
      await expect(storage.delete(KEY)).rejects.toBe(err);
    });

    it('AVATAR_BUCKET 未設定のとき何もしない', async () => {
      const storage = new GcsAvatarStorage(makeConfig({ AVATAR_BUCKET: '' }));
      await storage.delete(KEY);
      expect(mockDelete).not.toHaveBeenCalled();
    });
  });
});
