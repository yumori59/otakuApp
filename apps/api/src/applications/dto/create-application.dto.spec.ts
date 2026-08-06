import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import { CreateApplicationDto } from './create-application.dto';

const APP_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const EVENT_ID = '018f3c2a-eeee-7c90-9d2a-000000000001';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';

function companion(index: number, identityId: string | null = null) {
  return {
    id: `018f3c2a-ffff-7c90-9d2a-00000000000${index}`,
    identity_id: identityId,
    display_name: `同行者${index}`,
    position: index,
  };
}

const VALID_BODY = {
  id: APP_ID,
  tour: { id: TOUR_ID, name: 'STELLARIS LIVE TOUR 2026', artist_name_raw: 'STELLARIS' },
  event: {
    id: EVENT_ID,
    name: '大阪公演 Day1',
    venue_name_raw: '大阪城ホール',
    event_date: '2026-08-20',
    starts_at: '2026-08-20T11:00:00.000Z',
  },
  rep_identity_id: IDENTITY_ID,
};

function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(CreateApplicationDto, body);
  return {
    dto,
    errors: validateSync(dto, { whitelist: true, forbidNonWhitelisted: true }),
  };
}

/** ネスト先も含めた全プロパティ名を集める。 */
function errorProperties(
  errors: ReturnType<typeof validateSync>,
): string[] {
  return errors.flatMap((e) => [
    e.property,
    ...errorProperties(e.children ?? []),
  ]);
}

describe('CreateApplicationDto', () => {
  it('最小構成（tour.name / event.name / rep_identity_id）で通る', () => {
    const { errors } = validateBody(VALID_BODY);
    expect(errors).toHaveLength(0);
  });

  it('UUID v7 文字列の id は 400 にならない (BE-1)', () => {
    const { errors } = validateBody({ ...VALID_BODY, id: APP_ID });
    expect(errors).toHaveLength(0);
  });

  it('id / tour.id / event.id は省略できる（サーバー発行）', () => {
    const { errors } = validateBody({
      tour: { name: 'ツアー' },
      event: { name: '公演' },
      rep_identity_id: IDENTITY_ID,
    });
    expect(errors).toHaveLength(0);
  });

  it('rep_identity_id が UUID でなければエラー', () => {
    const { errors } = validateBody({
      ...VALID_BODY,
      rep_identity_id: 'not-a-uuid',
    });
    expect(errorProperties(errors)).toContain('rep_identity_id');
  });

  it('tour.name が空 / 201 文字はエラー', () => {
    expect(
      validateBody({ ...VALID_BODY, tour: { name: '' } }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ ...VALID_BODY, tour: { name: 'a'.repeat(201) } }).errors
        .length,
    ).toBeGreaterThan(0);
  });

  it('event.name が空 / 201 文字はエラー', () => {
    expect(
      validateBody({ ...VALID_BODY, event: { name: '' } }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ ...VALID_BODY, event: { name: 'a'.repeat(201) } }).errors
        .length,
    ).toBeGreaterThan(0);
  });

  it('tour / event キーが無ければエラー', () => {
    expect(
      validateBody({ rep_identity_id: IDENTITY_ID }).errors.length,
    ).toBeGreaterThan(0);
  });

  it('AC-APP-06 companions 3 件は通る', () => {
    const { errors } = validateBody({
      ...VALID_BODY,
      companions: [companion(1), companion(2), companion(3)],
    });
    expect(errors).toHaveLength(0);
  });

  it('AC-APP-06 companions 4 件は VALIDATION_ERROR 400 相当', () => {
    const { errors } = validateBody({
      ...VALID_BODY,
      companions: [companion(1), companion(2), companion(3), companion(4)],
    });
    expect(errorProperties(errors)).toContain('companions');
  });

  it('AC-APP-07 companions の identity_id 重複は 400 相当', () => {
    const { errors } = validateBody({
      ...VALID_BODY,
      companions: [companion(1, IDENTITY_ID), companion(2, IDENTITY_ID)],
    });
    expect(errorProperties(errors)).toContain('companions');
  });

  it('AC-APP-07 identity_id が null の companion は複数あってもよい', () => {
    const { errors } = validateBody({
      ...VALID_BODY,
      companions: [companion(1, null), companion(2, null)],
    });
    expect(errors).toHaveLength(0);
  });

  it('companions[].display_name が無ければエラー', () => {
    const { errors } = validateBody({
      ...VALID_BODY,
      companions: [{ id: '018f3c2a-ffff-7c90-9d2a-000000000001' }],
    });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-APP-09 status: "pending" は 400（applied に黙って落とさない — BE-2）', () => {
    const { dto, errors } = validateBody({ ...VALID_BODY, status: 'pending' });
    expect(errorProperties(errors)).toContain('status');
    expect(dto.status).not.toBe('applied');
  });

  it('AC-APP-09 status の許可値は draft/applied/won/lost/cancelled のみ', () => {
    for (const status of ['draft', 'applied', 'won', 'lost', 'cancelled']) {
      const { errors } = validateBody({ ...VALID_BODY, status });
      expect(errors).toHaveLength(0);
    }
  });

  it('ticket_count は 1〜20', () => {
    expect(
      validateBody({ ...VALID_BODY, ticket_count: 0 }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ ...VALID_BODY, ticket_count: 21 }).errors.length,
    ).toBeGreaterThan(0);
    expect(validateBody({ ...VALID_BODY, ticket_count: 20 }).errors).toHaveLength(
      0,
    );
  });

  it('price_yen は 0〜10,000,000', () => {
    expect(
      validateBody({ ...VALID_BODY, price_yen: -1 }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ ...VALID_BODY, price_yen: 10_000_001 }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ ...VALID_BODY, price_yen: 10_000_000 }).errors,
    ).toHaveLength(0);
  });

  it('note は 2000 文字まで', () => {
    expect(
      validateBody({ ...VALID_BODY, note: 'a'.repeat(2001) }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ ...VALID_BODY, note: 'a'.repeat(2000) }).errors,
    ).toHaveLength(0);
  });

  it('applied_on / result_on は YYYY-MM-DD のみ', () => {
    expect(
      validateBody({ ...VALID_BODY, applied_on: '2026-07-01T00:00:00Z' }).errors
        .length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ ...VALID_BODY, applied_on: '2026-07-01', result_on: '2026-07-20' })
        .errors,
    ).toHaveLength(0);
  });

  it('owner_id / event_id など契約外キーは拒否される', () => {
    expect(
      validateBody({ ...VALID_BODY, owner_id: IDENTITY_ID }).errors.length,
    ).toBeGreaterThan(0);
    expect(
      validateBody({ ...VALID_BODY, event_id: EVENT_ID }).errors.length,
    ).toBeGreaterThan(0);
  });
});
