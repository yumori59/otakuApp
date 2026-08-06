import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import { UpdateEventDto } from './update-event.dto';

function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(UpdateEventDto, body);
  return {
    dto,
    errors: validateSync(dto, { whitelist: true, forbidNonWhitelisted: true }),
  };
}

describe('UpdateEventDto', () => {
  it('tour_id の付け替えは受理しない（400 相当）', () => {
    const { errors } = validateBody({
      tour_id: '018f3c2a-dddd-7c90-9d2a-000000000002',
    });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('name / venue_name_raw / event_date / starts_at は受理する', () => {
    const { errors } = validateBody({
      name: '大阪公演 Day2',
      venue_name_raw: '大阪城ホール',
      event_date: '2026-08-21',
      starts_at: '2026-08-21T11:00:00.000Z',
    });
    expect(errors).toHaveLength(0);
  });

  it('event_date が YYYY-MM-DD でなければエラー', () => {
    const { errors } = validateBody({ event_date: '2026/08/21' });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('name が空文字 / 201 文字はエラー', () => {
    expect(validateBody({ name: '' }).errors.length).toBeGreaterThan(0);
    expect(
      validateBody({ name: 'a'.repeat(201) }).errors.length,
    ).toBeGreaterThan(0);
  });

  it('venue_name_raw / event_date / starts_at は null で消去できる', () => {
    const { errors } = validateBody({
      venue_name_raw: null,
      event_date: null,
      starts_at: null,
    });
    expect(errors).toHaveLength(0);
  });
});
