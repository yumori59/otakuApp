import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { ShareRecipientAccessService } from '../share-recipient-access.service';
import { SetHiddenUseCase } from './set-hidden.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';

describe('SetHiddenUseCase', () => {
  let access: { setHidden: jest.Mock };
  let useCase: SetHiddenUseCase;

  beforeEach(() => {
    access = { setHidden: jest.fn().mockResolvedValue(true) };
    useCase = new SetHiddenUseCase(
      access as unknown as ShareRecipientAccessService,
    );
  });

  it('POST 相当（hidden:true）で hiddenAt を立てる', async () => {
    await useCase.execute(USER_ID, SHARE_ID, true);
    expect(access.setHidden).toHaveBeenCalledWith(SHARE_ID, USER_ID, true);
  });

  it('DELETE 相当（hidden:false）で hiddenAt を戻す（取り消し）', async () => {
    await useCase.execute(USER_ID, SHARE_ID, false);
    expect(access.setHidden).toHaveBeenCalledWith(SHARE_ID, USER_ID, false);
  });

  it('招待されていない :id は 404 SHARE_INVALID', async () => {
    access.setHidden.mockResolvedValue(false);

    const error = (await useCase
      .execute(USER_ID, SHARE_ID, true)
      .catch((e: unknown) => e)) as AppError;

    expect(error).toBeInstanceOf(AppError);
    expect(error.code).toBe(ErrorCode.SHARE_INVALID);
    expect(error.getStatus()).toBe(404);
  });

  it('オーナー本人（招待行が無い）も 404 SHARE_INVALID', async () => {
    access.setHidden.mockResolvedValue(false);

    await expect(
      useCase.execute(USER_ID, SHARE_ID, true),
    ).rejects.toMatchObject({ code: ErrorCode.SHARE_INVALID });
  });

  it('冪等: 既に非表示でも 204 相当（例外を投げない）', async () => {
    access.setHidden.mockResolvedValue(true);
    await expect(
      useCase.execute(USER_ID, SHARE_ID, true),
    ).resolves.toBeUndefined();
  });
});
