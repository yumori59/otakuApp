import { ShareLink } from '@prisma/client';
import { ErrorCode } from '../../common/errors/error-codes';
import { sha256Hex } from '../../common/util/hash.util';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { PrismaService } from '../../prisma/prisma.service';
import { ToursService } from '../../tours/tours.service';
import { ShareRecipientsService } from '../share-recipients.service';
import { CreateShareDto } from '../dto/create-share.dto';
import { SharesService } from '../shares.service';
import { CreateShareUseCase } from './create-share.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OWN_ACCOUNT_ID = 'ACC-100000';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const RECIPIENT_ACCOUNT_ID = 'ACC-9F8E7D';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-01T00:00:00.000Z');
const DAY_MS = 24 * 60 * 60 * 1000;

function shareRowFrom(data: Record<string, unknown>): ShareLink {
  return {
    permission: 'read',
    maskMemberNo: true,
    scopeId: null,
    expiresAt: null,
    revokedAt: null,
    viewCount: 0,
    lastViewedAt: null,
    editCount: 0,
    lastEditedAt: null,
    createdAt: NOW,
    updatedAt: NOW,
    ...data,
  } as unknown as ShareLink;
}

/** `profiles` の accountId → 行の対応。テストごとに上書きできる。 */
function profileRow(accountId: string, userId: string, displayName: string | null = null) {
  return { id: userId, accountId, displayName };
}

describe('CreateShareUseCase', () => {
  let prisma: {
    shareLink: { create: jest.Mock; count: jest.Mock };
    shareRecipient: { createMany: jest.Mock };
    profile: { findUnique: jest.Mock; findMany: jest.Mock };
    event: { count: jest.Mock };
    $transaction: jest.Mock;
  };
  let shares: SharesService;
  let shareRecipients: ShareRecipientsService;
  let tours: { assertOwned: jest.Mock };
  let entitlements: { shareLimit: jest.Mock; shareWriteEventLimit: jest.Mock };
  let useCase: CreateShareUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = {
      shareLink: {
        create: jest.fn(({ data }) => Promise.resolve(shareRowFrom(data))),
        count: jest.fn().mockResolvedValue(0),
      },
      shareRecipient: { createMany: jest.fn().mockResolvedValue(undefined) },
      profile: {
        findUnique: jest
          .fn()
          .mockResolvedValue({ accountId: OWN_ACCOUNT_ID }),
        findMany: jest
          .fn()
          .mockResolvedValue([
            profileRow(RECIPIENT_ACCOUNT_ID, OTHER_USER_ID, 'ゆう'),
          ]),
      },
      event: { count: jest.fn().mockResolvedValue(0) },
      $transaction: jest.fn((cb: (tx: unknown) => unknown) => cb(prisma)),
    };
    shareRecipients = new ShareRecipientsService(
      prisma as unknown as PrismaService,
    );
    shares = new SharesService(
      prisma as unknown as PrismaService,
      shareRecipients,
    );
    tours = {
      assertOwned: jest
        .fn()
        .mockResolvedValue({ id: TOUR_ID, name: 'STELLARIS LIVE TOUR 2026' }),
    };
    entitlements = {
      shareLimit: jest.fn().mockResolvedValue(null),
      shareWriteEventLimit: jest.fn().mockResolvedValue(3),
    };

    useCase = new CreateShareUseCase(
      shares,
      tours as unknown as ToursService,
      entitlements as unknown as EntitlementsService,
      shareRecipients,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  function dto(overrides: Partial<CreateShareDto> = {}): CreateShareDto {
    return {
      scope_type: 'tour',
      scope_id: TOUR_ID,
      shared_with_account_ids: [RECIPIENT_ACCOUNT_ID],
      ...overrides,
    } as CreateShareDto;
  }

  it('AC-SH-01 生トークンを返し、DB には sha256 hex のみが保存される (FR-SH-1)', async () => {
    const res = await useCase.execute(USER_ID, dto());

    const data = prisma.shareLink.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(typeof res.token).toBe('string');
    expect(res.token.length).toBeGreaterThan(20);
    expect(data.tokenHash).toBe(sha256Hex(res.token));
    expect(Object.keys(data)).not.toContain('token');
    expect(JSON.stringify(data)).not.toContain(res.token);
    expect(res.url).toBe(`meigicho://share/${res.token}`);
  });

  it('AC-SH-04 expires_at 省略時は +30 日 (Q8)', async () => {
    await useCase.execute(USER_ID, dto());

    const data = prisma.shareLink.create.mock.calls[0][0].data as {
      expiresAt: Date;
    };
    expect(data.expiresAt.toISOString()).toBe(
      new Date(NOW.getTime() + 30 * DAY_MS).toISOString(),
    );
  });

  it('expires_at 指定時はその値を使う', async () => {
    const expiresAt = new Date(NOW.getTime() + 10 * DAY_MS).toISOString();

    await useCase.execute(USER_ID, dto({ expires_at: expiresAt }));

    const data = prisma.shareLink.create.mock.calls[0][0].data as {
      expiresAt: Date;
    };
    expect(data.expiresAt.toISOString()).toBe(expiresAt);
  });

  it('AC-SH-05 +365 日を超える expires_at は VALIDATION_ERROR 400（DTO を通らない経路の防御）', async () => {
    const expiresAt = new Date(NOW.getTime() + 366 * DAY_MS).toISOString();

    await expect(
      useCase.execute(USER_ID, dto({ expires_at: expiresAt })),
    ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
    expect(prisma.shareLink.create).not.toHaveBeenCalled();
  });

  it('AC-SH-02 free で有効リンク 1 本保持時の 2 本目は PLAN_LIMIT_SHARE 403 (Q7)', async () => {
    entitlements.shareLimit.mockResolvedValue(1);
    prisma.shareLink.count.mockResolvedValue(1);

    await expect(useCase.execute(USER_ID, dto())).rejects.toMatchObject({
      code: ErrorCode.PLAN_LIMIT_SHARE,
      details: { limit: 1, current: 1 },
    });
    expect(prisma.shareLink.create).not.toHaveBeenCalled();
  });

  it('AC-SH-03 上限判定は失効済み / 期限切れを除外して数える', async () => {
    entitlements.shareLimit.mockResolvedValue(1);
    await useCase.execute(USER_ID, dto());

    expect(prisma.shareLink.count).toHaveBeenCalledWith({
      where: {
        ownerId: USER_ID,
        revokedAt: null,
        OR: [{ expiresAt: null }, { expiresAt: { gt: NOW } }],
      },
    });
  });

  it('plus (shareLimit=null) は本数を数えずに発行できる', async () => {
    entitlements.shareLimit.mockResolvedValue(null);

    await useCase.execute(USER_ID, dto());

    expect(prisma.shareLink.count).not.toHaveBeenCalled();
    expect(prisma.shareLink.create).toHaveBeenCalled();
  });

  it('AC-SH-07 他人 / 未知の scope_id (tour) は NOT_FOUND 404 (BE-4)', async () => {
    tours.assertOwned.mockRejectedValue(
      Object.assign(new Error('tour not found'), {
        code: ErrorCode.NOT_FOUND,
      }),
    );

    await expect(useCase.execute(USER_ID, dto())).rejects.toMatchObject({
      code: ErrorCode.NOT_FOUND,
    });
    expect(tours.assertOwned).toHaveBeenCalledWith(USER_ID, TOUR_ID);
    expect(prisma.shareLink.create).not.toHaveBeenCalled();
  });

  it('scope_type=tour で scope_id が無ければ VALIDATION_ERROR 400', async () => {
    await expect(
      useCase.execute(USER_ID, dto({ scope_id: undefined })),
    ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
    expect(prisma.shareLink.create).not.toHaveBeenCalled();
  });

  it('AC-SH-06 scope_type=identity_summary に scope_id を送ると VALIDATION_ERROR 400', async () => {
    await expect(
      useCase.execute(
        USER_ID,
        dto({ scope_type: 'identity_summary', scope_id: TOUR_ID }),
      ),
    ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
    expect(prisma.shareLink.create).not.toHaveBeenCalled();
  });

  it('identity_summary は tour 所有検証をせず scope_id を null で保存する', async () => {
    const res = await useCase.execute(
      USER_ID,
      dto({ scope_type: 'identity_summary', scope_id: undefined }),
    );

    expect(tours.assertOwned).not.toHaveBeenCalled();
    const data = prisma.shareLink.create.mock.calls[0][0].data as {
      scopeId: string | null;
    };
    expect(data.scopeId).toBeNull();
    expect(res.scope_id).toBeNull();
  });

  it('mask_member_no を保存する（既定は true）', async () => {
    await useCase.execute(USER_ID, dto());
    const defaults = prisma.shareLink.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(defaults.maskMemberNo).toBe(true);

    prisma.shareLink.create.mockClear();
    await useCase.execute(USER_ID, dto({ mask_member_no: false }));
    const explicit = prisma.shareLink.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(explicit.maskMemberNo).toBe(false);
  });

  it('share_links に shared_with_account_ids を書かない（列は削除済み / FR-5-4）', async () => {
    await useCase.execute(USER_ID, dto());
    const data = prisma.shareLink.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
    expect(data).not.toHaveProperty('sharedWithAccountIds');
  });

  describe('招待 (api-contract-delta.md §1)', () => {
    it('AC-SI-01 shared_with_account_ids が未指定は VALIDATION_ERROR 400（DTO を通らない経路の防御）', async () => {
      await expect(
        useCase.execute(
          USER_ID,
          dto({ shared_with_account_ids: undefined }),
        ),
      ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
      expect(prisma.shareLink.create).not.toHaveBeenCalled();
    });

    it('AC-SI-01 shared_with_account_ids が空配列は VALIDATION_ERROR 400', async () => {
      await expect(
        useCase.execute(USER_ID, dto({ shared_with_account_ids: [] })),
      ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
      expect(prisma.shareLink.create).not.toHaveBeenCalled();
    });

    it('AC-SI-02 存在しない ACC-ID は SHARE_RECIPIENT_UNKNOWN 400 + details。共有は作られない', async () => {
      prisma.profile.findMany.mockResolvedValue([]);

      await expect(
        useCase.execute(
          USER_ID,
          dto({ shared_with_account_ids: ['ACC-000000'] }),
        ),
      ).rejects.toMatchObject({
        code: ErrorCode.SHARE_RECIPIENT_UNKNOWN,
        details: { unknown_account_ids: ['ACC-000000'] },
      });
      expect(prisma.shareLink.create).not.toHaveBeenCalled();
    });

    it('AC-SI-03 成功時、share_recipients に招待件数分の行が user_id 解決済みで作られる', async () => {
      await useCase.execute(USER_ID, dto());

      expect(prisma.shareRecipient.createMany).toHaveBeenCalledWith({
        data: [
          expect.objectContaining({
            accountId: RECIPIENT_ACCOUNT_ID,
            userId: OTHER_USER_ID,
          }),
        ],
      });
    });

    it('AC-SI-04 同じ ACC-ID の重複指定は重複排除して 1 行だけ作る（400 にしない）', async () => {
      await useCase.execute(
        USER_ID,
        dto({
          shared_with_account_ids: [
            RECIPIENT_ACCOUNT_ID,
            RECIPIENT_ACCOUNT_ID,
          ],
        }),
      );

      const call = prisma.shareRecipient.createMany.mock.calls[0][0] as {
        data: unknown[];
      };
      expect(call.data).toHaveLength(1);
    });

    it('AC-SI-06 自分自身の ACC-ID を招待すると SHARE_RECIPIENT_SELF 400', async () => {
      await expect(
        useCase.execute(
          USER_ID,
          dto({ shared_with_account_ids: [OWN_ACCOUNT_ID] }),
        ),
      ).rejects.toMatchObject({ code: ErrorCode.SHARE_RECIPIENT_SELF });
      expect(prisma.shareLink.create).not.toHaveBeenCalled();
    });

    it('AC-SI-13 判定順序: Free で上限超過かつ未知 ID 混在なら SHARE_RECIPIENT_UNKNOWN が先に返る', async () => {
      entitlements.shareLimit.mockResolvedValue(1);
      prisma.shareLink.count.mockResolvedValue(1);
      prisma.profile.findMany.mockResolvedValue([]);

      await expect(
        useCase.execute(
          USER_ID,
          dto({ shared_with_account_ids: ['ACC-000000'] }),
        ),
      ).rejects.toMatchObject({ code: ErrorCode.SHARE_RECIPIENT_UNKNOWN });
      expect(prisma.shareLink.create).not.toHaveBeenCalled();
    });

    it('AC-SI-13 self 判定は実在確認より先（未知 + self 混在でも SELF が先に返る）', async () => {
      prisma.profile.findMany.mockResolvedValue([]);

      await expect(
        useCase.execute(
          USER_ID,
          dto({
            shared_with_account_ids: [OWN_ACCOUNT_ID, 'ACC-000000'],
          }),
        ),
      ).rejects.toMatchObject({ code: ErrorCode.SHARE_RECIPIENT_SELF });
    });

    it('作成レスポンスの recipients は account_id / display_name / invited_at / last_viewed_at のみ', async () => {
      const res = await useCase.execute(USER_ID, dto());

      expect(res.recipients).toEqual([
        {
          account_id: RECIPIENT_ACCOUNT_ID,
          display_name: 'ゆう',
          invited_at: res.created_at,
          last_viewed_at: null,
        },
      ]);
    });
  });

  describe('permission (api-contract-delta.md §3)', () => {
    it('AC-SW-01 permission 省略時は read で保存する（既存クライアント互換）', async () => {
      const res = await useCase.execute(USER_ID, dto());

      const data = prisma.shareLink.create.mock.calls[0][0].data as Record<
        string,
        unknown
      >;
      expect(data.permission).toBe('read');
      expect(res.permission).toBe('read');
      expect(entitlements.shareWriteEventLimit).not.toHaveBeenCalled();
    });

    it('AC-SW-02 permission=write + tour は 201 で write が保存される', async () => {
      const res = await useCase.execute(USER_ID, dto({ permission: 'write' }));

      const data = prisma.shareLink.create.mock.calls[0][0].data as Record<
        string,
        unknown
      >;
      expect(data.permission).toBe('write');
      expect(res.permission).toBe('write');
    });

    it('AC-SW-03 permission=write + identity_summary は VALIDATION_ERROR 400', async () => {
      await expect(
        useCase.execute(
          USER_ID,
          dto({
            scope_type: 'identity_summary',
            scope_id: undefined,
            permission: 'write',
          }),
        ),
      ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
      expect(prisma.shareLink.create).not.toHaveBeenCalled();
    });

    it('AC-SW-04 DTO を通らない未知 permission は 400（read に落とさない — BE-2）', async () => {
      await expect(
        useCase.execute(
          USER_ID,
          dto({ permission: 'admin' as unknown as 'write' }),
        ),
      ).rejects.toMatchObject({ code: ErrorCode.VALIDATION_ERROR });
      expect(prisma.shareLink.create).not.toHaveBeenCalled();
    });

    it('AC-SW-05 free で未削除 event 4 件は PLAN_LIMIT_SHARE_WRITE 403 + details', async () => {
      prisma.event.count.mockResolvedValue(4);

      await expect(
        useCase.execute(USER_ID, dto({ permission: 'write' })),
      ).rejects.toMatchObject({
        code: ErrorCode.PLAN_LIMIT_SHARE_WRITE,
        details: { limit: 3, current: 4 },
      });
      expect(prisma.shareLink.create).not.toHaveBeenCalled();
    });

    it.each([[0], [3]])(
      'AC-SW-05 free で event %i 件（上限ちょうど / 0 件）は 201',
      async (count) => {
        prisma.event.count.mockResolvedValue(count);

        await expect(
          useCase.execute(USER_ID, dto({ permission: 'write' })),
        ).resolves.toMatchObject({ permission: 'write' });
      },
    );

    it('AC-SW-05 公演数は未削除 event を ownerId スコープで数える (BE-4 / AC-SW-05d)', async () => {
      await useCase.execute(USER_ID, dto({ permission: 'write' }));

      expect(prisma.event.count).toHaveBeenCalledWith({
        where: { tourId: TOUR_ID, ownerId: USER_ID, deletedAt: null },
      });
    });

    it('AC-SW-05b plus (shareWriteEventLimit=null) は event 10 件でも 201', async () => {
      entitlements.shareWriteEventLimit.mockResolvedValue(null);
      prisma.event.count.mockResolvedValue(10);

      await expect(
        useCase.execute(USER_ID, dto({ permission: 'write' })),
      ).resolves.toMatchObject({ permission: 'write' });
      expect(prisma.event.count).not.toHaveBeenCalled();
    });

    it('AC-SW-05c read リンクは公演数制限を受けない', async () => {
      prisma.event.count.mockResolvedValue(10);

      await expect(
        useCase.execute(USER_ID, dto({ permission: 'read' })),
      ).resolves.toMatchObject({ permission: 'read' });
      expect(entitlements.shareWriteEventLimit).not.toHaveBeenCalled();
    });

    it('本数上限 (PLAN_LIMIT_SHARE) を公演数上限より先に判定する', async () => {
      entitlements.shareLimit.mockResolvedValue(1);
      prisma.shareLink.count.mockResolvedValue(1);
      prisma.event.count.mockResolvedValue(99);

      await expect(
        useCase.execute(USER_ID, dto({ permission: 'write' })),
      ).rejects.toMatchObject({ code: ErrorCode.PLAN_LIMIT_SHARE });
    });
  });
});
