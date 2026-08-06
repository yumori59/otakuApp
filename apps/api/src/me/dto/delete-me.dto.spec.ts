import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import { DeleteMeDto } from './delete-me.dto';

function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(DeleteMeDto, body);
  return {
    dto,
    errors: validateSync(dto, { whitelist: true, forbidNonWhitelisted: true }),
  };
}

describe('DeleteMeDto', () => {
  it('AC-AD-01 空ボディはエラー無し（Apple / Google のみのアカウント）', () => {
    expect(validateBody({}).errors).toHaveLength(0);
  });

  it('AC-AD-04 password のみでも apple_authorization_code のみでも通る', () => {
    expect(
      validateBody({ password: 'correct horse battery' }).errors,
    ).toHaveLength(0);
    expect(
      validateBody({ apple_authorization_code: 'c1a2b3' }).errors,
    ).toHaveLength(0);
    expect(
      validateBody({
        password: 'correct horse battery',
        apple_authorization_code: 'c1a2b3',
      }).errors,
    ).toHaveLength(0);
  });

  it('AC-AD-02 空文字の password / apple_authorization_code は拒否する', () => {
    expect(validateBody({ password: '' }).errors.length).toBeGreaterThan(0);
    expect(
      validateBody({ apple_authorization_code: '' }).errors.length,
    ).toBeGreaterThan(0);
  });

  it('文字列以外の password は拒否する', () => {
    expect(validateBody({ password: 12345678 }).errors.length).toBeGreaterThan(
      0,
    );
    expect(validateBody({ password: true }).errors.length).toBeGreaterThan(0);
    expect(
      validateBody({ password: { value: 'x' } }).errors.length,
    ).toBeGreaterThan(0);
  });

  it('password: null は「未指定」として扱う（@IsOptional の既定挙動。必須判定は UseCase 側で 400）', () => {
    const { dto, errors } = validateBody({ password: null });
    expect(errors).toHaveLength(0);
    expect(dto.password).toBeNull();
  });

  it('契約 §1 password に長さ下限を掛けない（旧ポリシーのアカウントを 400 で締め出さない）', () => {
    expect(validateBody({ password: 'a' }).errors).toHaveLength(0);
    expect(validateBody({ password: 'short' }).errors).toHaveLength(0);
  });

  it('BE-4 user_id / owner_id など対象ユーザーを指定するキーは受け付けない', () => {
    expect(
      validateBody({ user_id: '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f' }).errors
        .length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ owner_id: '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f' }).errors
        .length,
    ).toBeGreaterThan(0);
  });

  it('契約に無いキー（appleAuthorizationCode の camelCase 誤用）は拒否する', () => {
    expect(
      validateBody({ appleAuthorizationCode: 'c1a2b3' }).errors.length,
    ).toBeGreaterThan(0);
  });
});
