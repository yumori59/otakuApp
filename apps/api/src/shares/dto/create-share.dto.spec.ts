import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validate } from 'class-validator';
import { CreateShareDto } from './create-share.dto';

const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-01T00:00:00.000Z');
const DAY_MS = 24 * 60 * 60 * 1000;
const ONE_ACCOUNT = ['ACC-3F9A21'];

function daysFromNow(days: number): string {
  return new Date(NOW.getTime() + days * DAY_MS).toISOString();
}

async function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(CreateShareDto, body);
  return { dto, errors: await validate(dto) };
}

describe('CreateShareDto', () => {
  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('scope_type=tour + scope_id(UUID) + shared_with_account_ids は通る', async () => {
    const { errors } = await validateBody({
      scope_type: 'tour',
      scope_id: TOUR_ID,
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors).toHaveLength(0);
  });

  it('scope_type=identity_summary は scope_id 無しで通る', async () => {
    const { errors } = await validateBody({
      scope_type: 'identity_summary',
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors).toHaveLength(0);
  });

  it('AC-SH-06 scope_type=identity_summary に scope_id を送ると 400', async () => {
    const { errors } = await validateBody({
      scope_type: 'identity_summary',
      scope_id: TOUR_ID,
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors.some((e) => e.property === 'scope_id')).toBe(true);
  });

  it('scope_type=tour で scope_id が無ければ 400', async () => {
    const { errors } = await validateBody({
      scope_type: 'tour',
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors.some((e) => e.property === 'scope_id')).toBe(true);
  });

  it('scope_type=tour で scope_id が UUID でなければ 400（BE-1: バージョンは検証しない）', async () => {
    const invalid = await validateBody({
      scope_type: 'tour',
      scope_id: 'not-a-uuid',
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(invalid.errors.some((e) => e.property === 'scope_id')).toBe(true);

    const v4 = await validateBody({
      scope_type: 'tour',
      scope_id: '3fa85f64-5717-4562-b3fc-2c963f66afa6',
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(v4.errors).toHaveLength(0);
  });

  it('未知の scope_type は 400（黙って別値に落とさない — BE-2）', async () => {
    const { dto, errors } = await validateBody({
      scope_type: 'calendar',
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors.some((e) => e.property === 'scope_type')).toBe(true);
    expect(dto.scope_type).not.toBe('tour');
    expect(dto.scope_type).not.toBe('identity_summary');
  });

  it('scope_type 欠落は 400', async () => {
    const { errors } = await validateBody({
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors.some((e) => e.property === 'scope_type')).toBe(true);
  });

  it('AC-SH-05 expires_at が +366 日は 400', async () => {
    const { errors } = await validateBody({
      scope_type: 'identity_summary',
      expires_at: daysFromNow(366),
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors.some((e) => e.property === 'expires_at')).toBe(true);
  });

  it('AC-SH-05 expires_at が +365 日以内なら通る', async () => {
    const { errors } = await validateBody({
      scope_type: 'identity_summary',
      expires_at: daysFromNow(364),
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors).toHaveLength(0);
  });

  it('expires_at が ISO8601 でなければ 400', async () => {
    const { errors } = await validateBody({
      scope_type: 'identity_summary',
      expires_at: '2026/08/31',
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors.some((e) => e.property === 'expires_at')).toBe(true);
  });

  describe('shared_with_account_ids (api-contract-delta.md §1)', () => {
    it('AC-SI-01 未指定は 400', async () => {
      const { errors } = await validateBody({
        scope_type: 'identity_summary',
      });
      expect(
        errors.some((e) => e.property === 'shared_with_account_ids'),
      ).toBe(true);
    });

    it('AC-SI-01 空配列は 400', async () => {
      const { errors } = await validateBody({
        scope_type: 'identity_summary',
        shared_with_account_ids: [],
      });
      expect(
        errors.some((e) => e.property === 'shared_with_account_ids'),
      ).toBe(true);
    });

    it('AC-SH-08 shared_with_account_ids の "ABC-123" は 400', async () => {
      const { errors } = await validateBody({
        scope_type: 'identity_summary',
        shared_with_account_ids: ['ABC-123'],
      });
      expect(
        errors.some((e) => e.property === 'shared_with_account_ids'),
      ).toBe(true);
    });

    it('AC-SH-08 shared_with_account_ids の ["ACC-3F9A21"] は通る', async () => {
      const { errors } = await validateBody({
        scope_type: 'identity_summary',
        shared_with_account_ids: ['ACC-3F9A21'],
      });
      expect(errors).toHaveLength(0);
    });

    it('AC-SI-05 小文字 hex "acc-3f9a21" は拒否する（既存 ACCOUNT_ID_RE を変えない — BE-2）', async () => {
      const { errors } = await validateBody({
        scope_type: 'identity_summary',
        shared_with_account_ids: ['ACC-3f9a21'],
      });
      expect(
        errors.some((e) => e.property === 'shared_with_account_ids'),
      ).toBe(true);
    });

    it('AC-SI-07 20 件までは通り、21 件は 400', async () => {
      const ok = await validateBody({
        scope_type: 'identity_summary',
        shared_with_account_ids: Array.from(
          { length: 20 },
          () => 'ACC-3F9A21',
        ),
      });
      expect(ok.errors).toHaveLength(0);

      const ng = await validateBody({
        scope_type: 'identity_summary',
        shared_with_account_ids: Array.from(
          { length: 21 },
          () => 'ACC-3F9A21',
        ),
      });
      expect(
        ng.errors.some((e) => e.property === 'shared_with_account_ids'),
      ).toBe(true);
    });

    it('AC-SI-04 重複要素は DTO では 400 にしない（use-case が重複排除する）', async () => {
      const { errors } = await validateBody({
        scope_type: 'identity_summary',
        shared_with_account_ids: ['ACC-3F9A21', 'ACC-3F9A21'],
      });
      expect(errors).toHaveLength(0);
    });
  });

  describe('permission (api-contract-delta.md §3)', () => {
    it('AC-SW-01 permission 省略は通り、値は undefined のまま（既定は use-case 側で read）', async () => {
      const { dto, errors } = await validateBody({
        scope_type: 'tour',
        scope_id: TOUR_ID,
        shared_with_account_ids: ONE_ACCOUNT,
      });
      expect(errors).toHaveLength(0);
      expect(dto.permission).toBeUndefined();
    });

    it('AC-SW-02 permission=write + scope_type=tour は通る', async () => {
      const { errors } = await validateBody({
        scope_type: 'tour',
        scope_id: TOUR_ID,
        permission: 'write',
        shared_with_account_ids: ONE_ACCOUNT,
      });
      expect(errors).toHaveLength(0);
    });

    it('permission=read はどちらの scope_type でも通る', async () => {
      const tour = await validateBody({
        scope_type: 'tour',
        scope_id: TOUR_ID,
        permission: 'read',
        shared_with_account_ids: ONE_ACCOUNT,
      });
      expect(tour.errors).toHaveLength(0);

      const summary = await validateBody({
        scope_type: 'identity_summary',
        permission: 'read',
        shared_with_account_ids: ONE_ACCOUNT,
      });
      expect(summary.errors).toHaveLength(0);
    });

    it('AC-SW-03 permission=write + identity_summary は 400', async () => {
      const { errors } = await validateBody({
        scope_type: 'identity_summary',
        permission: 'write',
        shared_with_account_ids: ONE_ACCOUNT,
      });
      expect(errors.some((e) => e.property === 'permission')).toBe(true);
    });

    it.each([['admin'], ['READ'], ['Write'], [''], [1]])(
      'AC-SW-04 未知の permission %p は 400（黙って read に落とさない — BE-2）',
      async (permission) => {
        const { dto, errors } = await validateBody({
          scope_type: 'tour',
          scope_id: TOUR_ID,
          permission,
          shared_with_account_ids: ONE_ACCOUNT,
        });
        expect(errors.some((e) => e.property === 'permission')).toBe(true);
        expect(dto.permission).not.toBe('read');
      },
    );
  });

  it('mask_member_no は boolean のみ', async () => {
    const { errors } = await validateBody({
      scope_type: 'identity_summary',
      mask_member_no: 'true',
      shared_with_account_ids: ONE_ACCOUNT,
    });
    expect(errors.some((e) => e.property === 'mask_member_no')).toBe(true);
  });
});
