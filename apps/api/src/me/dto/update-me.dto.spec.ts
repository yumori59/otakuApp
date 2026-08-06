import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import { UpdateMeDto } from './update-me.dto';

function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(UpdateMeDto, body);
  return {
    dto,
    errors: validateSync(dto, { whitelist: true, forbidNonWhitelisted: true }),
  };
}

describe('UpdateMeDto', () => {
  it('AC-ME-03 theme_color: "blue" は VALIDATION_ERROR 相当のエラーになる', () => {
    const { errors } = validateBody({ theme_color: 'blue' });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-ME-03 theme_color が "#RRGGBB" 形式なら通る', () => {
    const { errors } = validateBody({ theme_color: '#0017C1' });
    expect(errors).toHaveLength(0);
  });

  it('AC-ME-04 account_id を含むと forbidNonWhitelisted で拒否される（黙って無視しない）', () => {
    const { errors } = validateBody({ account_id: 'ACC-3F9A21' });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-ME-04 plan / id など読み取り専用キーを含むと拒否される', () => {
    expect(validateBody({ plan: 'plus' }).errors.length).toBeGreaterThan(0);
    expect(
      validateBody({ id: '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f' }).errors
        .length,
    ).toBeGreaterThan(0);
  });

  it('username は 1〜30 文字', () => {
    expect(validateBody({ username: '' }).errors.length).toBeGreaterThan(0);
    expect(
      validateBody({ username: 'a'.repeat(31) }).errors.length,
    ).toBeGreaterThan(0);
    expect(validateBody({ username: 'yuya' }).errors).toHaveLength(0);
  });

  it('app_display_name は 1〜30 文字', () => {
    expect(
      validateBody({ app_display_name: '' }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ app_display_name: 'a'.repeat(31) }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ app_display_name: '参戦名義帳' }).errors,
    ).toHaveLength(0);
  });

  it('onboarded_at は ISO8601 文字列を要求する', () => {
    expect(
      validateBody({ onboarded_at: 'not-a-date' }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ onboarded_at: '2026-08-01T09:00:00.000Z' }).errors,
    ).toHaveLength(0);
  });

  it('キー未指定のボディはエラー無し（すべて任意）', () => {
    expect(validateBody({}).errors).toHaveLength(0);
  });
});
