import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import { UpdateApplicationDto } from './update-application.dto';

const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const EVENT_ID = '018f3c2a-eeee-7c90-9d2a-000000000001';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';

function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(UpdateApplicationDto, body);
  return {
    dto,
    errors: validateSync(dto, { whitelist: true, forbidNonWhitelisted: true }),
  };
}

function companion(index: number, identityId: string | null = null) {
  return {
    id: `018f3c2a-ffff-7c90-9d2a-00000000000${index}`,
    identity_id: identityId,
    display_name: `同行者${index}`,
    position: index,
  };
}

describe('UpdateApplicationDto', () => {
  it('AC-APP-14 event_id を送ると 400 相当（付け替え不可）', () => {
    const { errors } = validateBody({ event_id: EVENT_ID });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-APP-14 tour_id を送ると 400 相当（付け替え不可）', () => {
    const { errors } = validateBody({ tour_id: TOUR_ID });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-APP-14 tour / event オブジェクトも受理しない', () => {
    expect(validateBody({ tour: { name: 'x' } }).errors.length).toBeGreaterThan(
      0,
    );
    expect(validateBody({ event: { name: 'x' } }).errors.length).toBeGreaterThan(
      0,
    );
  });

  it('空ボディ（変更なし）は通る', () => {
    const { errors } = validateBody({});
    expect(errors).toHaveLength(0);
  });

  it('変更可能キーは通る', () => {
    const { errors } = validateBody({
      rep_identity_id: IDENTITY_ID,
      rep_membership_id: '018f3c2a-bbbb-7c90-9d2a-000000000001',
      round_name: 'FC2次',
      applied_on: '2026-07-01',
      result_on: '2026-07-20',
      status: 'won',
      seat_raw: 'アリーナ A3',
      ticket_count: 2,
      price_yen: 16000,
      note: 'メモ',
      companions: [companion(1)],
    });
    expect(errors).toHaveLength(0);
  });

  it('status の未知値は 400（BE-2）', () => {
    const { dto, errors } = validateBody({ status: 'pending' });
    expect(errors.length).toBeGreaterThan(0);
    expect(dto.status).not.toBe('applied');
  });

  it('companions 4 件は 400', () => {
    const { errors } = validateBody({
      companions: [companion(1), companion(2), companion(3), companion(4)],
    });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('companions の identity_id 重複は 400', () => {
    const { errors } = validateBody({
      companions: [companion(1, IDENTITY_ID), companion(2, IDENTITY_ID)],
    });
    expect(errors.length).toBeGreaterThan(0);
  });

  it('AC-APP-13 companions: [] は受理する（全件ソフトデリート指示）', () => {
    const { dto, errors } = validateBody({ companions: [] });
    expect(errors).toHaveLength(0);
    expect(dto.companions).toEqual([]);
  });

  it('rep_membership_id は null で消去できる', () => {
    const { errors } = validateBody({ rep_membership_id: null });
    expect(errors).toHaveLength(0);
  });
});
