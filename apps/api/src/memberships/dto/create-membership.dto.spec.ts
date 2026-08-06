import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { CreateMembershipDto } from './create-membership.dto';

const VALID_BODY = {
  id: '018f3c2a-bbbb-7c90-9d2a-000000000001',
  identity_id: '018f3c2a-aaaa-7c90-9d2a-000000000001',
  fan_club_name_raw: 'STELLARIS OFFICIAL FAN CLUB',
};

function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(CreateMembershipDto, body, {
    excludeExtraneousValues: false,
  });
  return validate(dto, { whitelist: true, forbidNonWhitelisted: true });
}

describe('CreateMembershipDto', () => {
  it('必須フィールドのみのボディはエラー無し', async () => {
    const errors = await validateBody(VALID_BODY);
    expect(errors).toHaveLength(0);
  });

  it('AC-MB-03 member_no を含むボディは forbidNonWhitelisted で拒否される', async () => {
    const errors = await validateBody({ ...VALID_BODY, member_no: '1234567890' });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-MB-03 member_no_cipher を含むボディは forbidNonWhitelisted で拒否される', async () => {
    const errors = await validateBody({
      ...VALID_BODY,
      member_no_cipher: 'deadbeef',
    });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-MB-03 owner_id を含むボディは forbidNonWhitelisted で拒否される（BE-4: サーバー設定を上書きさせない）', async () => {
    const errors = await validateBody({
      ...VALID_BODY,
      owner_id: '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f',
    });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-MB-04 member_no_last4 が 5 文字なら 400 相当のエラー', async () => {
    const errors = await validateBody({ ...VALID_BODY, member_no_last4: '12345' });
    expect(errors.some((e) => e.property === 'member_no_last4')).toBe(true);
  });

  it('AC-MB-04 member_no_last4 が 4 文字英数なら通る', async () => {
    const errors = await validateBody({ ...VALID_BODY, member_no_last4: '4821' });
    expect(errors).toHaveLength(0);
  });

  it('AC-MB-04 member_no_last4 に記号を含むと 400 相当のエラー', async () => {
    const errors = await validateBody({ ...VALID_BODY, member_no_last4: '48-1' });
    expect(errors.some((e) => e.property === 'member_no_last4')).toBe(true);
  });

  it('AC-MB-05 fee_yen: -1 は 400 相当のエラー', async () => {
    const errors = await validateBody({ ...VALID_BODY, fee_yen: -1 });
    expect(errors.some((e) => e.property === 'fee_yen')).toBe(true);
  });

  it('AC-MB-05 fee_yen: 1000001 は 400 相当のエラー', async () => {
    const errors = await validateBody({ ...VALID_BODY, fee_yen: 1000001 });
    expect(errors.some((e) => e.property === 'fee_yen')).toBe(true);
  });

  it('fee_yen: 0 と 1000000 は境界として通る', async () => {
    expect(await validateBody({ ...VALID_BODY, fee_yen: 0 })).toHaveLength(0);
    expect(await validateBody({ ...VALID_BODY, fee_yen: 1000000 })).toHaveLength(0);
  });

  it('fan_club_name_raw が空文字なら 400 相当のエラー', async () => {
    const errors = await validateBody({ ...VALID_BODY, fan_club_name_raw: '' });
    expect(errors.some((e) => e.property === 'fan_club_name_raw')).toBe(true);
  });

  it('fan_club_name_raw が 201 文字なら 400 相当のエラー', async () => {
    const errors = await validateBody({
      ...VALID_BODY,
      fan_club_name_raw: 'a'.repeat(201),
    });
    expect(errors.some((e) => e.property === 'fan_club_name_raw')).toBe(true);
  });

  it('rank が 51 文字なら 400 相当のエラー', async () => {
    const errors = await validateBody({ ...VALID_BODY, rank: 'a'.repeat(51) });
    expect(errors.some((e) => e.property === 'rank')).toBe(true);
  });

  it('renewal_on が YYYY-MM-DD でなければ 400 相当のエラー', async () => {
    const errors = await validateBody({ ...VALID_BODY, renewal_on: '2026/09/15' });
    expect(errors.some((e) => e.property === 'renewal_on')).toBe(true);
  });

  it('id が UUID 形式でなければ 400 相当のエラー', async () => {
    const errors = await validateBody({ ...VALID_BODY, id: 'not-a-uuid' });
    expect(errors.some((e) => e.property === 'id')).toBe(true);
  });

  it('identity_id が UUID 形式でなければ 400 相当のエラー', async () => {
    const errors = await validateBody({ ...VALID_BODY, identity_id: 'not-a-uuid' });
    expect(errors.some((e) => e.property === 'identity_id')).toBe(true);
  });
});
