import 'reflect-metadata';
import { plainToInstance } from 'class-transformer';
import { validateSync } from 'class-validator';
import { GLOBAL_VALIDATION_OPTIONS } from '../../app.setup';
import { SyncPushDto } from './sync.dto';

const TOUR_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';

function errorProperties(
  errors: ReturnType<typeof validateSync>,
): string[] {
  return errors.flatMap((e) => [
    e.property,
    ...errorProperties(e.children ?? []),
  ]);
}

function validateBody(body: Record<string, unknown>) {
  const dto = plainToInstance(SyncPushDto, body);
  return {
    dto,
    errors: validateSync(dto, GLOBAL_VALIDATION_OPTIONS),
  };
}

describe('SyncPushDto', () => {
  it('AC-SYNC-1 payload を含む正常な mutation は 400 にならない（whitelist で payload が消えない）', () => {
    const { errors } = validateBody({
      mutations: [
        {
          collection: 'tours',
          op: 'upsert',
          id: TOUR_ID,
          updated_at: '2026-08-01T00:00:00.000Z',
          payload: { name: 'STELLARIS LIVE TOUR 2026' },
        },
      ],
    });
    expect(errorProperties(errors)).not.toContain('payload');
    expect(errors).toHaveLength(0);
  });

  it('payload が配列や文字列などオブジェクトでない場合はエラー', () => {
    const { errors } = validateBody({
      mutations: [
        {
          collection: 'tours',
          op: 'upsert',
          id: TOUR_ID,
          updated_at: '2026-08-01T00:00:00.000Z',
          payload: 'not-an-object',
        },
      ],
    });
    expect(errorProperties(errors)).toContain('payload');
  });
});
