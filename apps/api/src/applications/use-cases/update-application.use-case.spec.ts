import { ErrorCode } from '../../common/errors/error-codes';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { IdentitiesService } from '../../identities/identities.service';
import { PrismaService } from '../../prisma/prisma.service';
import { ApplicationsService } from '../applications.service';
import { UpdateApplicationDto } from '../dto/update-application.dto';
import { UpdateApplicationUseCase } from './update-application.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const APP_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const EVENT_ID = '018f3c2a-eeee-7c90-9d2a-000000000001';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';
const NEW_IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000009';
const MEMBERSHIP_ID = '018f3c2a-bbbb-7c90-9d2a-000000000001';
const COMPANION_1 = '018f3c2a-ffff-7c90-9d2a-000000000001';
const COMPANION_2 = '018f3c2a-ffff-7c90-9d2a-000000000002';
const COMPANION_3 = '018f3c2a-ffff-7c90-9d2a-000000000003';
const NOW = new Date('2026-07-31T12:05:00.000Z');

const IDENTITY_ROW = {
  id: IDENTITY_ID,
  ownerId: USER_ID,
  displayName: '自分',
  relation: 'self',
  color: '#0017C1',
  joinedOn: null,
  note: null,
  historyVisible: true,
  sortOrder: 0,
  createdAt: NOW,
  updatedAt: NOW,
  deletedAt: null,
};

function applicationRow(overrides: Record<string, unknown> = {}) {
  return {
    id: APP_ID,
    ownerId: USER_ID,
    eventId: EVENT_ID,
    repIdentityId: IDENTITY_ID,
    repMembershipId: null,
    roundName: 'FC1次',
    appliedOn: null,
    resultOn: null,
    status: 'applied',
    seatRaw: null,
    ticketCount: 1,
    priceYen: null,
    note: null,
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
    event: { tourId: TOUR_ID },
    companions: [],
    ...overrides,
  };
}

function companionRow(
  id: string,
  position: number,
  overrides: Record<string, unknown> = {},
) {
  return {
    id,
    ownerId: USER_ID,
    applicationId: APP_ID,
    identityId: null,
    displayName: `同行者${position}`,
    position,
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
    ...overrides,
  };
}

function makeClientMock() {
  return {
    identity: { findFirst: jest.fn() },
    membership: { findFirst: jest.fn() },
    application: {
      findUnique: jest.fn(),
      findFirst: jest.fn(),
      update: jest.fn(),
    },
    applicationCompanion: {
      findMany: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
      createMany: jest.fn(),
    },
  };
}

describe('UpdateApplicationUseCase', () => {
  let tx: ReturnType<typeof makeClientMock>;
  let prisma: ReturnType<typeof makeClientMock> & { $transaction: jest.Mock };
  let useCase: UpdateApplicationUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    tx = makeClientMock();
    prisma = {
      ...makeClientMock(),
      $transaction: jest.fn((cb: (client: unknown) => unknown) => cb(tx)),
    };

    tx.application.findFirst.mockResolvedValue(applicationRow());
    tx.application.findUnique.mockResolvedValue(applicationRow());
    tx.application.update.mockResolvedValue(applicationRow());
    tx.identity.findFirst.mockResolvedValue(IDENTITY_ROW);
    tx.applicationCompanion.findMany.mockResolvedValue([]);

    const prismaService = prisma as unknown as PrismaService;
    const applications = new ApplicationsService(prismaService);
    const identities = new IdentitiesService(
      prismaService,
      { identityLimit: jest.fn() } as unknown as EntitlementsService,
    );
    useCase = new UpdateApplicationUseCase(applications, identities);
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  function dto(body: Partial<UpdateApplicationDto>): UpdateApplicationDto {
    return body as UpdateApplicationDto;
  }

  it('他人 / 存在しない application の PATCH は NOT_FOUND 404 (BE-4)', async () => {
    tx.application.findFirst.mockResolvedValue(null);

    await expect(
      useCase.execute(OTHER_USER_ID, APP_ID, dto({ status: 'won' })),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    expect(tx.application.update).not.toHaveBeenCalled();
  });

  it('送られたキーのみ更新する（未指定キーを潰さない）', async () => {
    await useCase.execute(USER_ID, APP_ID, dto({ status: 'won' }));

    expect(tx.application.update).toHaveBeenCalledWith({
      where: { id: APP_ID },
      data: { status: 'won' },
    });
  });

  it('rep_identity_id 変更時は所有検証してから反映する', async () => {
    await useCase.execute(
      USER_ID,
      APP_ID,
      dto({ rep_identity_id: NEW_IDENTITY_ID }),
    );

    expect(tx.identity.findFirst).toHaveBeenCalledWith({
      where: { id: NEW_IDENTITY_ID, ownerId: USER_ID, deletedAt: null },
    });
    expect(tx.application.update).toHaveBeenCalledWith({
      where: { id: APP_ID },
      data: { repIdentityId: NEW_IDENTITY_ID },
    });
  });

  it('他人の rep_identity_id への変更は 404 で更新しない', async () => {
    tx.identity.findFirst.mockResolvedValue(null);

    await expect(
      useCase.execute(USER_ID, APP_ID, dto({ rep_identity_id: NEW_IDENTITY_ID })),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    expect(tx.application.update).not.toHaveBeenCalled();
  });

  it('rep_membership_id は更新後の rep_identity_id に属するか検証する', async () => {
    tx.membership.findFirst.mockResolvedValue(null);

    await expect(
      useCase.execute(
        USER_ID,
        APP_ID,
        dto({
          rep_identity_id: NEW_IDENTITY_ID,
          rep_membership_id: MEMBERSHIP_ID,
        }),
      ),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });

    expect(tx.membership.findFirst).toHaveBeenCalledWith({
      where: {
        id: MEMBERSHIP_ID,
        ownerId: USER_ID,
        identityId: NEW_IDENTITY_ID,
        deletedAt: null,
      },
    });
  });

  it('FR-AP-4 rep_identity_id 単独変更で、旧名義の rep_membership_id は自動クリアされる', async () => {
    tx.application.findFirst.mockResolvedValue(
      applicationRow({ repMembershipId: MEMBERSHIP_ID }),
    );
    // 新しい代表名義には属していない
    tx.membership.findFirst.mockResolvedValue(null);

    await useCase.execute(
      USER_ID,
      APP_ID,
      dto({ rep_identity_id: NEW_IDENTITY_ID }),
    );

    expect(tx.membership.findFirst).toHaveBeenCalledWith({
      where: {
        id: MEMBERSHIP_ID,
        ownerId: USER_ID,
        identityId: NEW_IDENTITY_ID,
        deletedAt: null,
      },
    });
    expect(tx.application.update).toHaveBeenCalledWith({
      where: { id: APP_ID },
      data: { repIdentityId: NEW_IDENTITY_ID, repMembershipId: null },
    });
  });

  it('FR-AP-4 rep_identity_id 単独変更でも、membership が新名義に属していれば維持する', async () => {
    tx.application.findFirst.mockResolvedValue(
      applicationRow({ repMembershipId: MEMBERSHIP_ID }),
    );
    tx.membership.findFirst.mockResolvedValue({ id: MEMBERSHIP_ID });

    await useCase.execute(
      USER_ID,
      APP_ID,
      dto({ rep_identity_id: NEW_IDENTITY_ID }),
    );

    expect(tx.application.update).toHaveBeenCalledWith({
      where: { id: APP_ID },
      data: { repIdentityId: NEW_IDENTITY_ID },
    });
  });

  it('FR-AP-4 rep_membership_id が元々 null なら再検証しない', async () => {
    await useCase.execute(
      USER_ID,
      APP_ID,
      dto({ rep_identity_id: NEW_IDENTITY_ID }),
    );

    expect(tx.membership.findFirst).not.toHaveBeenCalled();
  });

  it('FR-AP-4 rep_identity_id が現在値と同じなら再検証しない', async () => {
    tx.application.findFirst.mockResolvedValue(
      applicationRow({ repMembershipId: MEMBERSHIP_ID }),
    );

    await useCase.execute(USER_ID, APP_ID, dto({ rep_identity_id: IDENTITY_ID }));

    expect(tx.membership.findFirst).not.toHaveBeenCalled();
  });

  it('rep_membership_id: null は検証せずクリアする', async () => {
    await useCase.execute(USER_ID, APP_ID, dto({ rep_membership_id: null }));

    expect(tx.membership.findFirst).not.toHaveBeenCalled();
    expect(tx.application.update).toHaveBeenCalledWith({
      where: { id: APP_ID },
      data: { repMembershipId: null },
    });
  });

  it('AC-APP-11 companions 全置換: 既存3件 → 1件指定で残り2件に deleted_at が入る', async () => {
    tx.applicationCompanion.findMany.mockResolvedValue([
      companionRow(COMPANION_1, 0),
      companionRow(COMPANION_2, 1),
      companionRow(COMPANION_3, 2),
    ]);

    await useCase.execute(
      USER_ID,
      APP_ID,
      dto({
        companions: [
          { id: COMPANION_1, identity_id: null, display_name: '同行者0' },
        ],
      }),
    );

    expect(tx.applicationCompanion.updateMany).toHaveBeenCalledWith({
      where: { id: { in: [COMPANION_2, COMPANION_3] } },
      data: { deletedAt: NOW },
    });
    expect(tx.applicationCompanion.update).toHaveBeenCalledWith({
      where: { id: COMPANION_1 },
      data: {
        identityId: null,
        displayName: '同行者0',
        position: 0,
        deletedAt: null,
      },
    });
    expect(tx.applicationCompanion.create).not.toHaveBeenCalled();
  });

  it('BE-6 ソフトデリート済み companion の id を再送すると create せず復活させる', async () => {
    tx.applicationCompanion.findMany.mockResolvedValue([
      companionRow(COMPANION_1, 0, { deletedAt: NOW }),
    ]);

    await useCase.execute(
      USER_ID,
      APP_ID,
      dto({
        companions: [
          { id: COMPANION_1, identity_id: null, display_name: '戻した同行者' },
        ],
      }),
    );

    // 主キー重複 (P2002 → 500) を起こさない
    expect(tx.applicationCompanion.create).not.toHaveBeenCalled();
    expect(tx.applicationCompanion.update).toHaveBeenCalledWith({
      where: { id: COMPANION_1 },
      data: {
        identityId: null,
        displayName: '戻した同行者',
        position: 0,
        deletedAt: null,
      },
    });
  });

  it('BE-6 既に削除済みの companion に deleted_at を再スタンプしない', async () => {
    tx.applicationCompanion.findMany.mockResolvedValue([
      companionRow(COMPANION_1, 0),
      companionRow(COMPANION_2, 1, { deletedAt: NOW }),
    ]);

    await useCase.execute(USER_ID, APP_ID, dto({ companions: [] }));

    expect(tx.applicationCompanion.updateMany).toHaveBeenCalledWith({
      where: { id: { in: [COMPANION_1] } },
      data: { deletedAt: NOW },
    });
  });

  it('AC-APP-11 未知 id の companion は新規作成される', async () => {
    tx.applicationCompanion.findMany.mockResolvedValue([
      companionRow(COMPANION_1, 0),
    ]);

    await useCase.execute(
      USER_ID,
      APP_ID,
      dto({
        companions: [
          { id: COMPANION_2, identity_id: null, display_name: '新しい同行者' },
        ],
      }),
    );

    expect(tx.applicationCompanion.create).toHaveBeenCalledWith({
      data: {
        id: COMPANION_2,
        ownerId: USER_ID,
        applicationId: APP_ID,
        identityId: null,
        displayName: '新しい同行者',
        position: 0,
      },
    });
    expect(tx.applicationCompanion.updateMany).toHaveBeenCalledWith({
      where: { id: { in: [COMPANION_1] } },
      data: { deletedAt: NOW },
    });
  });

  it('AC-APP-12 companions キーが無ければ companions を一切触らない', async () => {
    tx.applicationCompanion.findMany.mockResolvedValue([
      companionRow(COMPANION_1, 0),
    ]);

    await useCase.execute(USER_ID, APP_ID, dto({ status: 'won' }));

    expect(tx.applicationCompanion.findMany).not.toHaveBeenCalled();
    expect(tx.applicationCompanion.update).not.toHaveBeenCalled();
    expect(tx.applicationCompanion.updateMany).not.toHaveBeenCalled();
    expect(tx.applicationCompanion.create).not.toHaveBeenCalled();
  });

  it('AC-APP-13 companions: [] は既存を全件ソフトデリートする', async () => {
    tx.applicationCompanion.findMany.mockResolvedValue([
      companionRow(COMPANION_1, 0),
      companionRow(COMPANION_2, 1),
    ]);

    await useCase.execute(USER_ID, APP_ID, dto({ companions: [] }));

    expect(tx.applicationCompanion.updateMany).toHaveBeenCalledWith({
      where: { id: { in: [COMPANION_1, COMPANION_2] } },
      data: { deletedAt: NOW },
    });
    expect(tx.applicationCompanion.create).not.toHaveBeenCalled();
  });

  it('companions の identity_id は所有検証される', async () => {
    tx.identity.findFirst.mockResolvedValue(null);

    await expect(
      useCase.execute(
        USER_ID,
        APP_ID,
        dto({
          companions: [
            {
              id: COMPANION_1,
              identity_id: NEW_IDENTITY_ID,
              display_name: '他人の名義',
            },
          ],
        }),
      ),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    expect(tx.applicationCompanion.update).not.toHaveBeenCalled();
    expect(tx.applicationCompanion.updateMany).not.toHaveBeenCalled();
  });

  it('更新は単一 $transaction 内で行われる', async () => {
    await useCase.execute(USER_ID, APP_ID, dto({ status: 'won' }));

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.application.update).not.toHaveBeenCalled();
  });
});
