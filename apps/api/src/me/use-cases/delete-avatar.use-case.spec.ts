import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AvatarService } from '../avatar/avatar.service';
import { AvatarStorage } from '../avatar/avatar.storage';
import { MeService } from '../me.service';
import { DeleteAvatarUseCase } from './delete-avatar.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const KEY = 'avatars/abc123.jpg';
const ME_VIEW_WITH_NULL = {
  user: {},
  profile: { avatar_url: null },
  entitlement: {},
};

describe('DeleteAvatarUseCase', () => {
  let avatarService: { remove: jest.Mock };
  let storage: { isConfigured: jest.Mock; delete: jest.Mock };
  let meService: { getMe: jest.Mock };
  let useCase: DeleteAvatarUseCase;

  beforeEach(() => {
    avatarService = { remove: jest.fn().mockResolvedValue({ previousKey: null }) };
    storage = {
      isConfigured: jest.fn().mockReturnValue(true),
      delete: jest.fn().mockResolvedValue(undefined),
    };
    meService = { getMe: jest.fn().mockResolvedValue(ME_VIEW_WITH_NULL) };
    useCase = new DeleteAvatarUseCase(
      avatarService as unknown as AvatarService,
      storage as unknown as AvatarStorage,
      meService as unknown as MeService,
    );
  });

  it('AC-AV-14 行あり → remove → delete(previousKey) → 200 avatar_url: null', async () => {
    avatarService.remove.mockResolvedValue({ previousKey: KEY });

    const result = await useCase.execute(USER_ID);

    expect(avatarService.remove).toHaveBeenCalledWith(USER_ID);
    expect(storage.delete).toHaveBeenCalledWith(KEY);
    expect(result).toBe(ME_VIEW_WITH_NULL);
  });

  it('AC-AV-14 行なし（未設定）→ storage.delete 未呼び出しで 200', async () => {
    avatarService.remove.mockResolvedValue({ previousKey: null });

    const result = await useCase.execute(USER_ID);

    expect(storage.delete).not.toHaveBeenCalled();
    expect(result).toBe(ME_VIEW_WITH_NULL);
  });

  it('storage.delete が reject しても 200 を返す', async () => {
    avatarService.remove.mockResolvedValue({ previousKey: KEY });
    storage.delete.mockRejectedValue(new Error('storage error'));

    const result = await useCase.execute(USER_ID);

    expect(result).toBe(ME_VIEW_WITH_NULL);
  });

  it('AVATAR_BUCKET 未設定（isConfigured false）のとき previousKey があっても storage.delete しない', async () => {
    storage.isConfigured.mockReturnValue(false);
    avatarService.remove.mockResolvedValue({ previousKey: KEY });

    await useCase.execute(USER_ID);

    expect(storage.delete).not.toHaveBeenCalled();
  });

  it('AC-AV-18 remove が SERVICE_UNAVAILABLE → そのまま 503', async () => {
    avatarService.remove.mockRejectedValue(
      new AppError(ErrorCode.SERVICE_UNAVAILABLE, 'avatar is temporarily unavailable'),
    );

    const err = await useCase.execute(USER_ID).catch((e: unknown) => e);

    expect(err).toBeInstanceOf(AppError);
    expect((err as AppError).code).toBe(ErrorCode.SERVICE_UNAVAILABLE);
  });
});
