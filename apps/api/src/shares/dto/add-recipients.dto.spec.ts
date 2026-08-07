import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { AddRecipientsDto } from './add-recipients.dto';

async function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(AddRecipientsDto, body);
  return { dto, errors: await validate(dto) };
}

describe('AddRecipientsDto', () => {
  it('["ACC-1A2B3C"] は通る', async () => {
    const { errors } = await validateBody({ account_ids: ['ACC-1A2B3C'] });
    expect(errors).toHaveLength(0);
  });

  it('未指定は 400', async () => {
    const { errors } = await validateBody({});
    expect(errors.some((e) => e.property === 'account_ids')).toBe(true);
  });

  it('空配列は 400', async () => {
    const { errors } = await validateBody({ account_ids: [] });
    expect(errors.some((e) => e.property === 'account_ids')).toBe(true);
  });

  it('小文字 hex は 400（既存 ACCOUNT_ID_RE を変えない — BE-2）', async () => {
    const { errors } = await validateBody({ account_ids: ['acc-1a2b3c'] });
    expect(errors.some((e) => e.property === 'account_ids')).toBe(true);
  });

  it('21 件は 400', async () => {
    const { errors } = await validateBody({
      account_ids: Array.from({ length: 21 }, () => 'ACC-1A2B3C'),
    });
    expect(errors.some((e) => e.property === 'account_ids')).toBe(true);
  });

  it('重複要素は DTO では 400 にしない', async () => {
    const { errors } = await validateBody({
      account_ids: ['ACC-1A2B3C', 'ACC-1A2B3C'],
    });
    expect(errors).toHaveLength(0);
  });
});
