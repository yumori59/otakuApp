import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { UpdateShareItemDto } from './update-share-item.dto';

const REV = 'cmV2LXNhbXBsZQ';

async function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(UpdateShareItemDto, body);
  return { dto, errors: await validate(dto) };
}

describe('UpdateShareItemDto', () => {
  it('rev + status は通る', async () => {
    const { errors } = await validateBody({ rev: REV, status: 'won' });
    expect(errors).toHaveLength(0);
  });

  it('rev + seat は通る', async () => {
    const { errors } = await validateBody({ rev: REV, seat: '1F A列 12番' });
    expect(errors).toHaveLength(0);
  });

  it('AC-SW-12 seat: null は通る（座席を消す）', async () => {
    const { errors } = await validateBody({ rev: REV, seat: null });
    expect(errors).toHaveLength(0);
  });

  it('AC-SW-12 seat: "" は通る（空文字として保存する）', async () => {
    const { dto, errors } = await validateBody({ rev: REV, seat: '' });
    expect(errors).toHaveLength(0);
    expect(dto.seat).toBe('');
  });

  it('AC-SW-19 status も seat も無いボディは 400', async () => {
    const { errors } = await validateBody({ rev: REV });
    expect(errors.some((e) => e.property === 'rev')).toBe(true);
  });

  it('rev が無ければ 400', async () => {
    const { errors } = await validateBody({ status: 'won' });
    expect(errors.some((e) => e.property === 'rev')).toBe(true);
  });

  it('rev が空文字なら 400', async () => {
    const { errors } = await validateBody({ rev: '', status: 'won' });
    expect(errors.some((e) => e.property === 'rev')).toBe(true);
  });

  it.each([['approved'], ['WON'], ['deleted'], [1], [null]])(
    'AC-SW-19 未知の status %p は 400（BE-2）',
    async (status) => {
      const { dto, errors } = await validateBody({ rev: REV, status });
      expect(errors.some((e) => e.property === 'status')).toBe(true);
      expect(dto.status).not.toBe('applied');
    },
  );

  it.each([['draft'], ['applied'], ['won'], ['lost'], ['cancelled']])(
    '契約の status %s は通る',
    async (status) => {
      const { errors } = await validateBody({ rev: REV, status });
      expect(errors).toHaveLength(0);
    },
  );

  it('seat は 200 文字まで、201 文字は 400', async () => {
    const ok = await validateBody({ rev: REV, seat: 'あ'.repeat(200) });
    expect(ok.errors).toHaveLength(0);

    const ng = await validateBody({ rev: REV, seat: 'あ'.repeat(201) });
    expect(ng.errors.some((e) => e.property === 'seat')).toBe(true);
  });

  it('seat が文字列でも null でもなければ 400', async () => {
    const { errors } = await validateBody({ rev: REV, seat: 12 });
    expect(errors.some((e) => e.property === 'seat')).toBe(true);
  });
});
