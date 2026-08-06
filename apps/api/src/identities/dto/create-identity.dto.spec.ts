import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { CreateIdentityDto } from './create-identity.dto';

const VALID_BODY = {
  id: '018f3c2a-aaaa-7c90-9d2a-000000000001',
  display_name: '自分',
};

describe('CreateIdentityDto', () => {
  it('AC-IDT-08 UUID v7 文字列の id は 400 にならない（BE-1: バージョン検証しない）', async () => {
    const dto = plainToInstance(CreateIdentityDto, VALID_BODY);
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });

  it('AC-IDT-08 UUID v4 文字列の id も 400 にならない', async () => {
    const dto = plainToInstance(CreateIdentityDto, {
      ...VALID_BODY,
      id: '3fa85f64-5717-4562-b3fc-2c963f66afa6',
    });
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });

  it('AC-IDT-08 id が UUID 形式でなければ 400 相当のエラー', async () => {
    const dto = plainToInstance(CreateIdentityDto, {
      ...VALID_BODY,
      id: 'not-a-uuid',
    });
    const errors = await validate(dto);
    expect(errors.some((e) => e.property === 'id')).toBe(true);
  });

  it('AC-IDT-07 relation: "boss" は不正値としてエラーになる（other に黙って落とさない）', async () => {
    const dto = plainToInstance(CreateIdentityDto, {
      ...VALID_BODY,
      relation: 'boss',
    });
    const errors = await validate(dto);
    const relationError = errors.find((e) => e.property === 'relation');
    expect(relationError).toBeDefined();
    expect(dto.relation).not.toBe('other');
  });

  it('AC-IDT-07 relation の許可値は self/family/friend/other のみ', async () => {
    for (const relation of ['self', 'family', 'friend', 'other']) {
      const dto = plainToInstance(CreateIdentityDto, { ...VALID_BODY, relation });
      const errors = await validate(dto);
      expect(errors).toHaveLength(0);
    }
  });

  it('display_name が空文字なら 400 相当のエラー', async () => {
    const dto = plainToInstance(CreateIdentityDto, { ...VALID_BODY, display_name: '' });
    const errors = await validate(dto);
    expect(errors.some((e) => e.property === 'display_name')).toBe(true);
  });

  it('display_name が 61 文字なら 400 相当のエラー', async () => {
    const dto = plainToInstance(CreateIdentityDto, {
      ...VALID_BODY,
      display_name: 'a'.repeat(61),
    });
    const errors = await validate(dto);
    expect(errors.some((e) => e.property === 'display_name')).toBe(true);
  });

  it('note が 2001 文字なら 400 相当のエラー', async () => {
    const dto = plainToInstance(CreateIdentityDto, {
      ...VALID_BODY,
      note: 'a'.repeat(2001),
    });
    const errors = await validate(dto);
    expect(errors.some((e) => e.property === 'note')).toBe(true);
  });

  it('color が 6 桁 hex でなければ 400 相当のエラー', async () => {
    const dto = plainToInstance(CreateIdentityDto, { ...VALID_BODY, color: '#FFF' });
    const errors = await validate(dto);
    expect(errors.some((e) => e.property === 'color')).toBe(true);
  });

  it('color が 6 桁 hex なら通る', async () => {
    const dto = plainToInstance(CreateIdentityDto, { ...VALID_BODY, color: '#0017C1' });
    const errors = await validate(dto);
    expect(errors).toHaveLength(0);
  });
});
