import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import { PaginationQueryDto } from './pagination.dto';

function validateQuery(query: Record<string, unknown>) {
  const dto = plainToInstance(PaginationQueryDto, query, {
    enableImplicitConversion: false,
  });
  return { dto, errors: validateSync(dto, { whitelist: true }) };
}

describe('PaginationQueryDto', () => {
  it('AC-APP-15 limit 未指定の既定は 50', () => {
    const { dto, errors } = validateQuery({});
    expect(errors).toHaveLength(0);
    expect(dto.limit).toBe(50);
  });

  it('AC-APP-15 limit=0 は検証エラー', () => {
    const { errors } = validateQuery({ limit: '0' });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-APP-15 limit=500 は検証エラー', () => {
    const { errors } = validateQuery({ limit: '500' });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-APP-15 limit=1 / 200 は許可され数値に変換される', () => {
    for (const raw of ['1', '200']) {
      const { dto, errors } = validateQuery({ limit: raw });
      expect(errors).toHaveLength(0);
      expect(dto.limit).toBe(Number(raw));
    }
  });

  it('AC-APP-15 limit が数値でなければ検証エラー', () => {
    const { errors } = validateQuery({ limit: 'abc' });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-APP-15 cursor は next_cursor をそのまま渡す opaque 文字列として受け取る', () => {
    const token = '2026-07-31T12:05:00.000Z|018f3c2a-cccc-7c90-9d2a-000000000001';
    const { dto, errors } = validateQuery({ cursor: token });
    expect(errors).toHaveLength(0);
    expect(dto.cursor).toBe(token);
  });

  it('AC-APP-15 cursor が文字列でなければ検証エラー', () => {
    const { errors } = validateQuery({ cursor: 12345 });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-APP-15 cursor が長すぎれば検証エラー', () => {
    const { errors } = validateQuery({ cursor: 'a'.repeat(201) });
    expect(errors.length).toBeGreaterThan(0);
  });
});
