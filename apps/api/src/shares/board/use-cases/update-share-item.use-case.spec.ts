import { Application, ShareLink, Tour } from '@prisma/client';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { EntitlementsService } from '../../../entitlements/entitlements.service';
import { SharesService } from '../../shares.service';
import {
  TourMatrixInternalRow,
  TourMatrixService,
} from '../../../tours/tour-matrix.service';
import { UpdateShareItemDto } from '../dto/update-share-item.dto';
import { shareItemKey, shareItemRev } from '../share-item-key';
import { SharedApplicationsService } from '../shared-applications.service';
import { UpdateShareItemUseCase } from './update-share-item.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const OTHER_SHARE_TOKEN_HASH = 'b'.repeat(64);
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';
const TOKEN_HASH = 'a'.repeat(64);
const RAW_TOKEN = 'raw-opaque-share-token';
const NOW = new Date('2026-08-02T10:00:00.000Z');
const UPDATED_AT = new Date('2026-08-01T09:00:00.000Z');
const NEXT_UPDATED_AT = new Date('2026-08-02T10:00:00.000Z');

function eventId(n: number): string {
  return `018f3c2a-eeee-7c90-9d2a-00000000000${n}`;
}

function applicationId(n: number): string {
  return `018f3c2a-cccc-7c90-9d2a-00000000000${n}`;
}

const APPLICATION_ID = applicationId(1);

function shareRow(overrides: Partial<ShareLink> = {}): ShareLink {
  return {
    id: SHARE_ID,
    ownerId: USER_ID,
    scopeType: 'tour',
    scopeId: TOUR_ID,
    tokenHash: TOKEN_HASH,
    permission: 'write',
    maskMemberNo: true,
    expiresAt: new Date('2026-08-31T00:00:00.000Z'),
    revokedAt: null,
    viewCount: 3,
    lastViewedAt: null,
    editCount: 0,
    lastEditedAt: null,
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
    ...overrides,
  } as ShareLink;
}

function tourRow(): Tour {
  return {
    id: TOUR_ID,
    ownerId: USER_ID,
    name: 'STELLARIS LIVE TOUR 2026',
    artistNameRaw: 'STELLARIS',
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
  } as Tour;
}

function matrixRow(
  overrides: Partial<TourMatrixInternalRow> = {},
): TourMatrixInternalRow {
  return {
    event_id: eventId(1),
    event_name: '大阪公演 Day1',
    venue_name: '大阪城ホール',
    event_date: '2026-08-20',
    application_id: APPLICATION_ID,
    round_name: 'FC1次',
    status: 'applied',
    seat_raw: null,
    result_on: null,
    rep_identity_id: IDENTITY_ID,
    rep_name: '自分',
    rep_color: '#0017C1',
    companion_names: ['妹'],
    rep_history_visible: true,
    ...overrides,
  };
}

function updatedApplication(
  overrides: Partial<Application> = {},
): Application {
  return {
    id: APPLICATION_ID,
    ownerId: USER_ID,
    status: 'won',
    seatRaw: null,
    updatedAt: NEXT_UPDATED_AT,
    deletedAt: null,
    ...overrides,
  } as Application;
}

/** ネストしたオブジェクト・配列を再帰的に走査してキー名を全部集める。 */
function collectKeys(value: unknown, acc: string[] = []): string[] {
  if (Array.isArray(value)) {
    value.forEach((v) => collectKeys(v, acc));
    return acc;
  }
  if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      acc.push(key);
      collectKeys(child, acc);
    }
  }
  return acc;
}

describe('UpdateShareItemUseCase', () => {
  let shares: {
    findByToken: jest.Mock;
    recordEdit: jest.Mock;
    recordView: jest.Mock;
  };
  let tourMatrix: { build: jest.Mock };
  let sharedApplications: {
    findUpdatedAtByTour: jest.Mock;
    findOwned: jest.Mock;
    updateIfUnchanged: jest.Mock;
  };
  let entitlements: { shareWriteEventLimit: jest.Mock };
  let useCase: UpdateShareItemUseCase;
  /** 実ログを出さずに内容だけ検証する（AC-SW-28）。 */
  let logged: string[];

  const validItemKey = () => shareItemKey(TOKEN_HASH, APPLICATION_ID);
  const validRev = () => shareItemRev(TOKEN_HASH, APPLICATION_ID, UPDATED_AT);

  function dto(overrides: Partial<UpdateShareItemDto> = {}): UpdateShareItemDto {
    return { rev: validRev(), status: 'won', ...overrides } as UpdateShareItemDto;
  }

  function setRows(rows: TourMatrixInternalRow[]): void {
    tourMatrix.build.mockResolvedValue({ tour: tourRow(), rows });
    sharedApplications.findUpdatedAtByTour.mockResolvedValue(
      new Map(rows.map((row) => [row.application_id, UPDATED_AT])),
    );
  }

  function expectNoWrite(): void {
    expect(sharedApplications.updateIfUnchanged).not.toHaveBeenCalled();
    expect(shares.recordEdit).not.toHaveBeenCalled();
  }

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    shares = {
      findByToken: jest.fn().mockResolvedValue(shareRow()),
      recordEdit: jest.fn().mockResolvedValue(undefined),
      recordView: jest.fn().mockResolvedValue(undefined),
    };
    tourMatrix = { build: jest.fn() };
    sharedApplications = {
      findUpdatedAtByTour: jest.fn(),
      findOwned: jest.fn().mockResolvedValue(null),
      updateIfUnchanged: jest.fn().mockResolvedValue(updatedApplication()),
    };
    entitlements = { shareWriteEventLimit: jest.fn().mockResolvedValue(3) };
    setRows([matrixRow()]);

    useCase = new UpdateShareItemUseCase(
      shares as unknown as SharesService,
      tourMatrix as unknown as TourMatrixService,
      sharedApplications as unknown as SharedApplicationsService,
      entitlements as unknown as EntitlementsService,
    );

    logged = [];
    jest
      .spyOn(
        (useCase as unknown as { logger: { log: (m: string) => void } }).logger,
        'log',
      )
      .mockImplementation((message: string) => {
        logged.push(message);
      });
  });

  afterEach(() => {
    jest.restoreAllMocks();
    jest.useRealTimers();
  });

  describe('① トークン (AC-SW-14)', () => {
    const cases: Array<[string, ShareLink | null]> = [
      ['未知トークン', null],
      [
        '失効済み',
        shareRow({ revokedAt: new Date('2026-08-01T00:00:00.000Z') }),
      ],
      ['期限切れ', shareRow({ expiresAt: new Date('2026-08-02T09:59:59.999Z') })],
      ['期限ちょうど', shareRow({ expiresAt: NOW })],
    ];

    it.each(cases)('%s は SHARE_INVALID 404・DB 不変', async (_label, row) => {
      shares.findByToken.mockResolvedValue(row);

      const error = (await useCase
        .execute(RAW_TOKEN, validItemKey(), dto())
        .catch((e: unknown) => e)) as AppError;

      expect(error.code).toBe(ErrorCode.SHARE_INVALID);
      expect(error.getStatus()).toBe(404);
      expect(error.message).not.toContain(SHARE_ID);
      expect(error.message).not.toContain(TOUR_ID);
      expectNoWrite();
      expect(tourMatrix.build).not.toHaveBeenCalled();
    });

    it('4 パターンのエラー本文が完全に一致する', async () => {
      const bodies: string[] = [];
      for (const [, row] of cases) {
        shares.findByToken.mockResolvedValue(row);
        const error = (await useCase
          .execute(RAW_TOKEN, validItemKey(), dto())
          .catch((e: unknown) => e)) as AppError;
        bodies.push(JSON.stringify(error.getResponse()));
      }
      expect(new Set(bodies).size).toBe(1);
    });
  });

  describe('② permission (AC-SW-13)', () => {
    it('read リンクへの PATCH は FORBIDDEN 403・DB 不変', async () => {
      shares.findByToken.mockResolvedValue(shareRow({ permission: 'read' }));

      const error = (await useCase
        .execute(RAW_TOKEN, validItemKey(), dto())
        .catch((e: unknown) => e)) as AppError;

      expect(error.code).toBe(ErrorCode.FORBIDDEN);
      expect(error.getStatus()).toBe(403);
      expectNoWrite();
    });

    it('未知の permission も write ではないので 403（read に落とさない — BE-2）', async () => {
      shares.findByToken.mockResolvedValue(shareRow({ permission: 'admin' }));

      await expect(
        useCase.execute(RAW_TOKEN, validItemKey(), dto()),
      ).rejects.toMatchObject({ code: ErrorCode.FORBIDDEN });
      expectNoWrite();
    });
  });

  describe('③ scope_type', () => {
    it('identity_summary リンクは FORBIDDEN 403', async () => {
      shares.findByToken.mockResolvedValue(
        shareRow({ scopeType: 'identity_summary', scopeId: null }),
      );

      await expect(
        useCase.execute(RAW_TOKEN, validItemKey(), dto()),
      ).rejects.toMatchObject({ code: ErrorCode.FORBIDDEN });
      expectNoWrite();
    });

    it('scope_id 欠損の tour リンクも FORBIDDEN 403', async () => {
      shares.findByToken.mockResolvedValue(shareRow({ scopeId: null }));

      await expect(
        useCase.execute(RAW_TOKEN, validItemKey(), dto()),
      ).rejects.toMatchObject({ code: ErrorCode.FORBIDDEN });
      expectNoWrite();
    });
  });

  describe('④ ボディ (AC-SW-19)', () => {
    it('status も seat も無ければ VALIDATION_ERROR 400（Pipe を通らない経路の防御）', async () => {
      const error = (await useCase
        .execute(RAW_TOKEN, validItemKey(), {
          rev: validRev(),
        } as UpdateShareItemDto)
        .catch((e: unknown) => e)) as AppError;

      expect(error.code).toBe(ErrorCode.VALIDATION_ERROR);
      expectNoWrite();
    });

    it('item_key 不一致より先にボディを検証する（判定順序 ④ → ⑤）', async () => {
      await expect(
        useCase.execute(RAW_TOKEN, 'totally-wrong-key', {
          rev: validRev(),
        } as UpdateShareItemDto),
      ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
    });
  });

  describe('⑤ item_key (AC-SW-15)', () => {
    it('でたらめな item_key は SHARE_INVALID 404（403 と区別しない）', async () => {
      await expect(
        useCase.execute(RAW_TOKEN, 'not-a-real-item-key', dto()),
      ).rejects.toMatchObject({ code: ErrorCode.SHARE_INVALID });
      expectNoWrite();
    });

    it('他リンクの item_key は SHARE_INVALID 404', async () => {
      const otherKey = shareItemKey(OTHER_SHARE_TOKEN_HASH, APPLICATION_ID);

      await expect(
        useCase.execute(RAW_TOKEN, otherKey, dto()),
      ).rejects.toMatchObject({ code: ErrorCode.SHARE_INVALID });
      expectNoWrite();
    });

    it('AC-SW-24 削除済み application は matrix に出ないので 404', async () => {
      setRows([]);

      await expect(
        useCase.execute(RAW_TOKEN, validItemKey(), dto()),
      ).rejects.toMatchObject({ code: ErrorCode.SHARE_INVALID });
      expectNoWrite();
    });

    it('AC-SW-24 scope tour が論理削除済みなら SHARE_INVALID 404（内部 id を出さない）', async () => {
      tourMatrix.build.mockRejectedValue(
        AppError.notFound(`tour not found: ${TOUR_ID}`),
      );

      const error = (await useCase
        .execute(RAW_TOKEN, validItemKey(), dto())
        .catch((e: unknown) => e)) as AppError;

      expect(error.code).toBe(ErrorCode.SHARE_INVALID);
      expect(JSON.stringify(error.getResponse())).not.toContain(TOUR_ID);
      expectNoWrite();
    });
  });

  describe('⑥ editable (AC-SW-16 / AC-SW-17)', () => {
    it('history_visible=false の行は FORBIDDEN 403・DB 不変', async () => {
      setRows([matrixRow({ rep_history_visible: false })]);

      const error = (await useCase
        .execute(RAW_TOKEN, validItemKey(), dto())
        .catch((e: unknown) => e)) as AppError;

      expect(error.code).toBe(ErrorCode.FORBIDDEN);
      expectNoWrite();
    });

    it('公演数上限を超えた行は FORBIDDEN 403・DB 不変', async () => {
      entitlements.shareWriteEventLimit.mockResolvedValue(1);
      setRows([
        matrixRow({ event_id: eventId(1), application_id: applicationId(9) }),
        matrixRow({ event_id: eventId(2), application_id: APPLICATION_ID }),
      ]);

      const error = (await useCase
        .execute(RAW_TOKEN, validItemKey(), dto())
        .catch((e: unknown) => e)) as AppError;

      expect(error.code).toBe(ErrorCode.FORBIDDEN);
      expectNoWrite();
    });

    it('AC-SW-17 プラン超過と非公開名義でエラー本文が完全に一致する（理由を漏らさない）', async () => {
      setRows([matrixRow({ rep_history_visible: false })]);
      const hidden = (await useCase
        .execute(RAW_TOKEN, validItemKey(), dto())
        .catch((e: unknown) => e)) as AppError;

      entitlements.shareWriteEventLimit.mockResolvedValue(1);
      setRows([
        matrixRow({ event_id: eventId(1), application_id: applicationId(9) }),
        matrixRow({ event_id: eventId(2), application_id: APPLICATION_ID }),
      ]);
      const overLimit = (await useCase
        .execute(RAW_TOKEN, validItemKey(), dto())
        .catch((e: unknown) => e)) as AppError;

      expect(JSON.stringify(hidden.getResponse())).toBe(
        JSON.stringify(overLimit.getResponse()),
      );
      expect(JSON.stringify(overLimit.getResponse())).not.toContain(
        ErrorCode.PLAN_LIMIT_SHARE_WRITE,
      );
    });

    it('AC-SW-10b オーナーが plus (limit=null) なら上限判定で 403 にならない', async () => {
      entitlements.shareWriteEventLimit.mockResolvedValue(null);
      setRows([
        matrixRow({ event_id: eventId(1), application_id: applicationId(9) }),
        matrixRow({ event_id: eventId(2), application_id: APPLICATION_ID }),
      ]);

      await expect(
        useCase.execute(RAW_TOKEN, validItemKey(), dto()),
      ).resolves.toMatchObject({ editable: true });
    });
  });

  describe('⑦ rev (AC-SW-18)', () => {
    it('rev 不一致は CONFLICT 409 + details.current・DB 不変', async () => {
      setRows([matrixRow({ status: 'lost', seat_raw: null })]);

      const error = (await useCase
        .execute(RAW_TOKEN, validItemKey(), dto({ rev: 'stale-rev-value' }))
        .catch((e: unknown) => e)) as AppError;

      expect(error.code).toBe(ErrorCode.CONFLICT);
      expect(error.getStatus()).toBe(409);
      expect(error.details).toEqual({
        current: { status: 'lost', seat: null, rev: validRev() },
      });
      expectNoWrite();
    });

    it('条件付き更新が 0 件（同時更新）なら現在値を読み直して CONFLICT 409', async () => {
      sharedApplications.updateIfUnchanged.mockResolvedValue(null);
      sharedApplications.findOwned.mockResolvedValue(
        updatedApplication({
          status: 'lost',
          seatRaw: '1F A列 12番',
          updatedAt: NEXT_UPDATED_AT,
        }),
      );

      const error = (await useCase
        .execute(RAW_TOKEN, validItemKey(), dto())
        .catch((e: unknown) => e)) as AppError;

      expect(error.code).toBe(ErrorCode.CONFLICT);
      expect(error.details).toEqual({
        current: {
          status: 'lost',
          seat: '1F A列 12番',
          rev: shareItemRev(TOKEN_HASH, APPLICATION_ID, NEXT_UPDATED_AT),
        },
      });
      expect(shares.recordEdit).not.toHaveBeenCalled();
    });

    it('同時更新で行自体が消えていたら SHARE_INVALID 404', async () => {
      sharedApplications.updateIfUnchanged.mockResolvedValue(null);
      sharedApplications.findOwned.mockResolvedValue(null);

      await expect(
        useCase.execute(RAW_TOKEN, validItemKey(), dto()),
      ).rejects.toMatchObject({ code: ErrorCode.SHARE_INVALID });
      expect(shares.recordEdit).not.toHaveBeenCalled();
    });
  });

  describe('成功時', () => {
    it('AC-SW-11 status を更新し、200 と新しい rev を返す', async () => {
      const item = await useCase.execute(RAW_TOKEN, validItemKey(), dto());

      expect(sharedApplications.updateIfUnchanged).toHaveBeenCalledWith(
        USER_ID,
        APPLICATION_ID,
        UPDATED_AT,
        { status: 'won' },
      );
      expect(item.status).toBe('won');
      expect(item.rev).toBe(
        shareItemRev(TOKEN_HASH, APPLICATION_ID, NEXT_UPDATED_AT),
      );
      expect(item.rev).not.toBe(validRev());
      expect(item.item_key).toBe(validItemKey());
      expect(item.editable).toBe(true);
    });

    it('AC-SW-12 seat 文字列 / null / 空文字をそのまま保存する', async () => {
      for (const seat of ['1F A列 12番', null, '']) {
        sharedApplications.updateIfUnchanged.mockResolvedValue(
          updatedApplication({ seatRaw: seat }),
        );

        const item = await useCase.execute(
          RAW_TOKEN,
          validItemKey(),
          dto({ status: undefined, seat }),
        );

        expect(sharedApplications.updateIfUnchanged).toHaveBeenLastCalledWith(
          USER_ID,
          APPLICATION_ID,
          UPDATED_AT,
          { seatRaw: seat },
        );
        expect(item.seat).toBe(seat);
      }
    });

    it('AC-SW-20 / AC-SW-21 成功時だけ edit_count を +1（view_count は触らない）', async () => {
      await useCase.execute(RAW_TOKEN, validItemKey(), dto());

      expect(shares.recordEdit).toHaveBeenCalledWith(SHARE_ID, NOW);
      expect(shares.recordView).not.toHaveBeenCalled();
    });

    it('AC-SW-22 レスポンスに内部 UUID / owner_id / account_id / 会員番号が含まれない', async () => {
      const item = await useCase.execute(RAW_TOKEN, validItemKey(), dto());

      const keys = collectKeys(item);
      const json = JSON.stringify(item);
      for (const forbiddenKey of [
        'id',
        'application_id',
        'event_id',
        'tour_id',
        'identity_id',
        'rep_identity_id',
        'owner_id',
        'ownerId',
        'account_id',
        'member_no',
        'member_no_last4',
        'token',
        'token_hash',
      ]) {
        expect(keys).not.toContain(forbiddenKey);
      }
      for (const forbiddenValue of [
        USER_ID,
        SHARE_ID,
        TOUR_ID,
        APPLICATION_ID,
        IDENTITY_ID,
        TOKEN_HASH,
      ]) {
        expect(json).not.toContain(forbiddenValue);
      }
    });

    it('GET の item と同じキー構成で返す', async () => {
      const item = await useCase.execute(RAW_TOKEN, validItemKey(), dto());

      expect(Object.keys(item).sort()).toEqual(
        [
          'event_name',
          'venue',
          'event_date',
          'round_name',
          'rep_name',
          'rep_color',
          'companions',
          'status',
          'seat',
          'item_key',
          'rev',
          'editable',
        ].sort(),
      );
    });

    it('共有元オーナーの ownerId でしか読み書きしない (BE-4)', async () => {
      await useCase.execute(RAW_TOKEN, validItemKey(), dto());

      expect(tourMatrix.build).toHaveBeenCalledWith(USER_ID, TOUR_ID);
      expect(sharedApplications.findUpdatedAtByTour).toHaveBeenCalledWith(
        USER_ID,
        TOUR_ID,
      );
      expect(entitlements.shareWriteEventLimit).toHaveBeenCalledWith(USER_ID);
    });

    it('AC-SW-28 ログに変更キー名だけを出し、座席文字列は出さない', async () => {
      sharedApplications.updateIfUnchanged.mockResolvedValue(
        updatedApplication({ seatRaw: '1F A列 12番' }),
      );

      await useCase.execute(
        RAW_TOKEN,
        validItemKey(),
        dto({ seat: '1F A列 12番' }),
      );

      expect(logged).toHaveLength(1);
      expect(logged[0]).toContain(SHARE_ID);
      expect(logged[0]).toContain(APPLICATION_ID);
      expect(logged[0]).toContain('seatRaw');
      expect(logged[0]).toContain('status');
      expect(logged[0]).not.toContain('1F A列 12番');
    });
  });
});
