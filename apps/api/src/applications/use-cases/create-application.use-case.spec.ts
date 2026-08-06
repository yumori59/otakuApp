import { ErrorCode } from '../../common/errors/error-codes';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { EventsService } from '../../events/events.service';
import { IdentitiesService } from '../../identities/identities.service';
import { PrismaService } from '../../prisma/prisma.service';
import { ToursService } from '../../tours/tours.service';
import { ApplicationsService } from '../applications.service';
import { CreateApplicationDto } from '../dto/create-application.dto';
import { CreateApplicationUseCase } from './create-application.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const APP_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const EVENT_ID = '018f3c2a-eeee-7c90-9d2a-000000000001';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';
const SISTER_IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000002';
const MEMBERSHIP_ID = '018f3c2a-bbbb-7c90-9d2a-000000000001';
const COMPANION_ID = '018f3c2a-ffff-7c90-9d2a-000000000001';
const NOW = new Date('2026-07-31T12:05:00.000Z');

const TOUR_ROW = {
  id: TOUR_ID,
  ownerId: USER_ID,
  name: 'STELLARIS LIVE TOUR 2026',
  artistNameRaw: 'STELLARIS',
  createdAt: NOW,
  updatedAt: NOW,
  deletedAt: null,
};

const EVENT_ROW = {
  id: EVENT_ID,
  ownerId: USER_ID,
  tourId: TOUR_ID,
  name: '大阪公演 Day1',
  venueNameRaw: '大阪城ホール',
  eventDate: new Date('2026-08-20T00:00:00.000Z'),
  startsAt: new Date('2026-08-20T11:00:00.000Z'),
  createdAt: NOW,
  updatedAt: NOW,
  deletedAt: null,
};

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
    appliedOn: new Date('2026-07-01T00:00:00.000Z'),
    resultOn: null,
    status: 'applied',
    seatRaw: null,
    ticketCount: 2,
    priceYen: 16000,
    note: null,
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
    event: { tourId: TOUR_ID },
    companions: [],
    ...overrides,
  };
}

function validDto(overrides: Partial<CreateApplicationDto> = {}) {
  return {
    id: APP_ID,
    tour: {
      id: TOUR_ID,
      name: 'STELLARIS LIVE TOUR 2026',
      artist_name_raw: 'STELLARIS',
    },
    event: {
      id: EVENT_ID,
      name: '大阪公演 Day1',
      venue_name_raw: '大阪城ホール',
      event_date: '2026-08-20',
      starts_at: '2026-08-20T11:00:00.000Z',
    },
    rep_identity_id: IDENTITY_ID,
    round_name: 'FC1次',
    applied_on: '2026-07-01',
    ticket_count: 2,
    price_yen: 16000,
    ...overrides,
  } as CreateApplicationDto;
}

function makeClientMock() {
  return {
    tour: {
      findUnique: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      findFirst: jest.fn(),
    },
    event: {
      findUnique: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      findFirst: jest.fn(),
    },
    identity: { findFirst: jest.fn() },
    membership: { findFirst: jest.fn() },
    application: {
      findUnique: jest.fn(),
      findFirst: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
    },
    applicationCompanion: {
      createMany: jest.fn(),
      findMany: jest.fn(),
      create: jest.fn(),
      update: jest.fn(),
      updateMany: jest.fn(),
    },
  };
}

describe('CreateApplicationUseCase', () => {
  let tx: ReturnType<typeof makeClientMock>;
  let prisma: ReturnType<typeof makeClientMock> & { $transaction: jest.Mock };
  let useCase: CreateApplicationUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    tx = makeClientMock();
    prisma = {
      ...makeClientMock(),
      $transaction: jest.fn((cb: (client: unknown) => unknown) => cb(tx)),
    };

    // 既定: 新規作成が成功する経路
    tx.application.findUnique.mockResolvedValue(null);
    tx.tour.findUnique.mockResolvedValue(null);
    tx.tour.create.mockResolvedValue(TOUR_ROW);
    tx.event.findUnique.mockResolvedValue(null);
    tx.event.create.mockResolvedValue(EVENT_ROW);
    tx.identity.findFirst.mockResolvedValue(IDENTITY_ROW);
    tx.application.create.mockResolvedValue(applicationRow());
    tx.applicationCompanion.createMany.mockResolvedValue({ count: 0 });

    const prismaService = prisma as unknown as PrismaService;
    const tours = new ToursService(prismaService);
    const events = new EventsService(prismaService);
    const identities = new IdentitiesService(
      prismaService,
      { identityLimit: jest.fn() } as unknown as EntitlementsService,
    );
    const applications = new ApplicationsService(prismaService);
    useCase = new CreateApplicationUseCase(
      applications,
      tours,
      events,
      identities,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  function mockFinalRead(row = applicationRow()) {
    tx.application.findUnique
      .mockResolvedValueOnce(null) // 重複 id チェック
      .mockResolvedValue(row); // 作成後の再取得
  }

  it('AC-APP-03 tour / event / application / companions を単一 $transaction 内で作る', async () => {
    mockFinalRead();

    await useCase.execute(USER_ID, validDto());

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(tx.tour.create).toHaveBeenCalled();
    expect(tx.event.create).toHaveBeenCalled();
    expect(tx.application.create).toHaveBeenCalled();
    // TX 外のクライアントでは一切書き込まない
    expect(prisma.tour.create).not.toHaveBeenCalled();
    expect(prisma.event.create).not.toHaveBeenCalled();
    expect(prisma.application.create).not.toHaveBeenCalled();
  });

  it('AC-APP-01 同名 tour があれば再利用し、新規 tour を作らない', async () => {
    tx.tour.findUnique.mockResolvedValue(TOUR_ROW);
    mockFinalRead();

    await useCase.execute(USER_ID, validDto());

    expect(tx.tour.findUnique).toHaveBeenCalledWith({
      where: {
        ownerId_name: { ownerId: USER_ID, name: 'STELLARIS LIVE TOUR 2026' },
      },
    });
    expect(tx.tour.create).not.toHaveBeenCalled();
    expect(tx.event.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ tourId: TOUR_ID }),
      }),
    );
  });

  it('AC-APP-02 ソフトデリート済み同名 tour は deleted_at を null にして再利用する', async () => {
    tx.tour.findUnique.mockResolvedValue({ ...TOUR_ROW, deletedAt: NOW });
    tx.tour.update.mockResolvedValue(TOUR_ROW);
    mockFinalRead();

    await useCase.execute(USER_ID, validDto());

    expect(tx.tour.update).toHaveBeenCalledWith({
      where: { id: TOUR_ID },
      data: { deletedAt: null, artistNameRaw: 'STELLARIS' },
    });
    expect(tx.tour.create).not.toHaveBeenCalled();
  });

  it('AC-APP-04 他人の rep_identity_id は 404、application も companions も作られない（TX ロールバック）', async () => {
    tx.identity.findFirst.mockResolvedValue(null);
    mockFinalRead();

    await expect(
      useCase.execute(USER_ID, validDto({ rep_identity_id: IDENTITY_ID })),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });

    expect(tx.application.create).not.toHaveBeenCalled();
    expect(tx.applicationCompanion.createMany).not.toHaveBeenCalled();
    // tour / event の書き込みは TX クライアント上でのみ発生 → 例外伝播でロールバックされる
    expect(prisma.tour.create).not.toHaveBeenCalled();
    expect(prisma.event.create).not.toHaveBeenCalled();
    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
  });

  it('AC-APP-04 rep_identity_id の検証は tx クライアントで行う', async () => {
    mockFinalRead();

    await useCase.execute(USER_ID, validDto());

    expect(tx.identity.findFirst).toHaveBeenCalledWith({
      where: { id: IDENTITY_ID, ownerId: USER_ID, deletedAt: null },
    });
    expect(prisma.identity.findFirst).not.toHaveBeenCalled();
  });

  it('AC-APP-04 他人の event id を指定すると 404 で application を作らない', async () => {
    tx.event.findUnique.mockResolvedValue({
      ...EVENT_ROW,
      ownerId: OTHER_USER_ID,
    });
    mockFinalRead();

    await expect(useCase.execute(USER_ID, validDto())).rejects.toMatchObject({
      code: ErrorCode.NOT_FOUND,
    });
    expect(tx.application.create).not.toHaveBeenCalled();
  });

  it('AC-APP-05 rep_membership_id が rep_identity_id に属さないと 404', async () => {
    tx.membership.findFirst.mockResolvedValue(null);
    mockFinalRead();

    await expect(
      useCase.execute(
        USER_ID,
        validDto({ rep_membership_id: MEMBERSHIP_ID }),
      ),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });

    expect(tx.membership.findFirst).toHaveBeenCalledWith({
      where: {
        id: MEMBERSHIP_ID,
        ownerId: USER_ID,
        identityId: IDENTITY_ID,
        deletedAt: null,
      },
    });
    expect(tx.application.create).not.toHaveBeenCalled();
  });

  it('AC-APP-05 rep_membership_id が正しければ作成される', async () => {
    tx.membership.findFirst.mockResolvedValue({
      id: MEMBERSHIP_ID,
      ownerId: USER_ID,
      identityId: IDENTITY_ID,
      deletedAt: null,
    });
    mockFinalRead(applicationRow({ repMembershipId: MEMBERSHIP_ID }));

    const result = await useCase.execute(
      USER_ID,
      validDto({ rep_membership_id: MEMBERSHIP_ID }),
    );

    expect(result.rep_membership_id).toBe(MEMBERSHIP_ID);
  });

  it('companions[].identity_id が他人のものなら 404 で application を作らない', async () => {
    tx.identity.findFirst
      .mockResolvedValueOnce(IDENTITY_ROW) // rep
      .mockResolvedValueOnce(null); // companion
    mockFinalRead();

    await expect(
      useCase.execute(
        USER_ID,
        validDto({
          companions: [
            {
              id: COMPANION_ID,
              identity_id: SISTER_IDENTITY_ID,
              display_name: '妹',
            },
          ],
        }),
      ),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    expect(tx.application.create).not.toHaveBeenCalled();
  });

  it('AC-APP-08 companions 0 件でも作成でき、レスポンスは companions: []', async () => {
    mockFinalRead();

    const result = await useCase.execute(USER_ID, validDto());

    expect(result.companions).toEqual([]);
    expect(tx.applicationCompanion.createMany).not.toHaveBeenCalled();
  });

  it('companions は ownerId をサーバー設定で作成する (BE-4)', async () => {
    tx.identity.findFirst.mockResolvedValue(IDENTITY_ROW);
    mockFinalRead(
      applicationRow({
        companions: [
          {
            id: COMPANION_ID,
            identityId: SISTER_IDENTITY_ID,
            displayName: '妹',
            position: 0,
          },
        ],
      }),
    );

    const result = await useCase.execute(
      USER_ID,
      validDto({
        companions: [
          {
            id: COMPANION_ID,
            identity_id: SISTER_IDENTITY_ID,
            display_name: '妹',
          },
        ],
      }),
    );

    expect(tx.applicationCompanion.createMany).toHaveBeenCalledWith({
      data: [
        {
          id: COMPANION_ID,
          ownerId: USER_ID,
          applicationId: APP_ID,
          identityId: SISTER_IDENTITY_ID,
          displayName: '妹',
          position: 0,
        },
      ],
    });
    expect(result.companions).toEqual([
      {
        id: COMPANION_ID,
        identity_id: SISTER_IDENTITY_ID,
        display_name: '妹',
        position: 0,
      },
    ]);
  });

  it('AC-APP-10 status 省略時は applied', async () => {
    mockFinalRead();

    await useCase.execute(USER_ID, validDto());

    expect(tx.application.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ status: 'applied' }),
      }),
    );
  });

  it('status 明示時はその値を使う（黙って applied に落とさない — BE-2）', async () => {
    mockFinalRead();

    await useCase.execute(USER_ID, validDto({ status: 'draft' }));

    expect(tx.application.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ status: 'draft' }),
      }),
    );
  });

  it('ticket_count 省略時の既定は 1', async () => {
    mockFinalRead();
    const dto = validDto();
    delete (dto as { ticket_count?: number }).ticket_count;

    await useCase.execute(USER_ID, dto);

    expect(tx.application.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ ticketCount: 1 }),
      }),
    );
  });

  it('ownerId はリクエストではなく認証ユーザーから設定される (BE-4)', async () => {
    mockFinalRead();

    await useCase.execute(USER_ID, validDto());

    expect(tx.application.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ ownerId: USER_ID, eventId: EVENT_ID }),
      }),
    );
  });

  it('既存 id の再 POST は CONFLICT 409（tour / event も作らない）', async () => {
    tx.application.findUnique.mockResolvedValue(applicationRow());

    await expect(useCase.execute(USER_ID, validDto())).rejects.toMatchObject({
      code: ErrorCode.CONFLICT,
    });
    expect(tx.tour.create).not.toHaveBeenCalled();
    expect(tx.event.create).not.toHaveBeenCalled();
    expect(tx.application.create).not.toHaveBeenCalled();
  });

  it('日付は YYYY-MM-DD → UTC 0 時で保存される (E-12)', async () => {
    mockFinalRead();

    await useCase.execute(
      USER_ID,
      validDto({ applied_on: '2026-07-01', result_on: '2026-07-20' }),
    );

    expect(tx.application.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          appliedOn: new Date('2026-07-01T00:00:00.000Z'),
          resultOn: new Date('2026-07-20T00:00:00.000Z'),
        }),
      }),
    );
  });
});
