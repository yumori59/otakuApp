import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { PrismaService } from '../prisma/prisma.service';
import { TourMatrixService } from './tour-matrix.service';
import { ToursService } from './tours.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OTHER_USER_ID = '018f3c2a-7b1e-7c90-9d2a-000000000099';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const EVENT_ID = '018f3c2a-eeee-7c90-9d2a-000000000001';
const APP_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';
const IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000001';
const SISTER_IDENTITY_ID = '018f3c2a-aaaa-7c90-9d2a-000000000002';
const NOW = new Date('2026-08-01T00:00:00.000Z');

const TOUR = {
  id: TOUR_ID,
  ownerId: USER_ID,
  name: 'STELLARIS LIVE TOUR 2026',
  artistNameRaw: 'STELLARIS',
  createdAt: NOW,
  updatedAt: NOW,
  deletedAt: null,
};

function eventWithApplications(overrides: Record<string, unknown> = {}) {
  return {
    id: EVENT_ID,
    ownerId: USER_ID,
    tourId: TOUR_ID,
    name: '大阪公演 Day1',
    venueNameRaw: '大阪城ホール',
    eventDate: new Date('2026-08-20T00:00:00.000Z'),
    startsAt: null,
    createdAt: NOW,
    updatedAt: NOW,
    deletedAt: null,
    applications: [
      {
        id: APP_ID,
        roundName: 'FC1次',
        status: 'applied',
        seatRaw: null,
        resultOn: new Date('2026-07-20T00:00:00.000Z'),
        repIdentityId: IDENTITY_ID,
        repIdentity: {
          id: IDENTITY_ID,
          displayName: '自分',
          color: '#0017C1',
          historyVisible: true,
        },
        companions: [
          {
            id: '018f3c2a-ffff-7c90-9d2a-000000000001',
            identityId: SISTER_IDENTITY_ID,
            displayName: '保存時の名前',
            position: 0,
            identity: { id: SISTER_IDENTITY_ID, displayName: '妹' },
          },
          {
            id: '018f3c2a-ffff-7c90-9d2a-000000000002',
            identityId: null,
            displayName: '友人B',
            position: 1,
            identity: null,
          },
        ],
      },
    ],
    ...overrides,
  };
}

describe('TourMatrixService', () => {
  let prisma: { event: { findMany: jest.Mock } };
  let tours: { assertOwned: jest.Mock };
  let service: TourMatrixService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    prisma = { event: { findMany: jest.fn() } };
    tours = { assertOwned: jest.fn().mockResolvedValue(TOUR) };
    service = new TourMatrixService(
      prisma as unknown as PrismaService,
      tours as unknown as ToursService,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('AC-APP-18 event_date asc nulls last / event_name asc で並べ、削除済み event / application を含まない', async () => {
    prisma.event.findMany.mockResolvedValue([eventWithApplications()]);

    await service.buildMatrix(USER_ID, TOUR_ID);

    expect(prisma.event.findMany).toHaveBeenCalledWith({
      where: { tourId: TOUR_ID, ownerId: USER_ID, deletedAt: null },
      orderBy: [
        { eventDate: { sort: 'asc', nulls: 'last' } },
        { name: 'asc' },
      ],
      include: {
        applications: {
          where: { deletedAt: null },
          orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
          include: {
            repIdentity: true,
            companions: {
              where: { deletedAt: null },
              orderBy: { position: 'asc' },
              include: { identity: true },
            },
          },
        },
      },
    });
  });

  it('AC-APP-18 matrix のレスポンス形（tour_id / tour_name / rows）', async () => {
    prisma.event.findMany.mockResolvedValue([eventWithApplications()]);

    const result = await service.buildMatrix(USER_ID, TOUR_ID);

    expect(result).toEqual({
      tour_id: TOUR_ID,
      tour_name: 'STELLARIS LIVE TOUR 2026',
      rows: [
        {
          event_id: EVENT_ID,
          event_name: '大阪公演 Day1',
          venue_name: '大阪城ホール',
          event_date: '2026-08-20',
          application_id: APP_ID,
          round_name: 'FC1次',
          status: 'applied',
          seat_raw: null,
          result_on: '2026-07-20',
          rep_identity_id: IDENTITY_ID,
          rep_name: '自分',
          rep_color: '#0017C1',
          companion_names: ['妹', '友人B'],
        },
      ],
    });
  });

  it('AC-APP-19 companion_names は配列で、identity_id があれば identity の現在名を使う', async () => {
    prisma.event.findMany.mockResolvedValue([eventWithApplications()]);

    const result = await service.buildMatrix(USER_ID, TOUR_ID);

    expect(Array.isArray(result.rows[0].companion_names)).toBe(true);
    expect(result.rows[0].companion_names).toEqual(['妹', '友人B']);
  });

  it('AC-APP-19 companions が 0 件なら空配列', async () => {
    const event = eventWithApplications();
    event.applications[0].companions = [];
    prisma.event.findMany.mockResolvedValue([event]);

    const result = await service.buildMatrix(USER_ID, TOUR_ID);

    expect(result.rows[0].companion_names).toEqual([]);
  });

  it('AC-APP-20 他人の tour の matrix は NOT_FOUND 404（event クエリも走らない）', async () => {
    tours.assertOwned.mockRejectedValue(AppError.notFound('tour not found'));

    await expect(
      service.buildMatrix(OTHER_USER_ID, TOUR_ID),
    ).rejects.toMatchObject({ code: ErrorCode.NOT_FOUND });
    expect(prisma.event.findMany).not.toHaveBeenCalled();
  });

  it('event_date が null なら event_date は null', async () => {
    prisma.event.findMany.mockResolvedValue([
      eventWithApplications({ eventDate: null }),
    ]);

    const result = await service.buildMatrix(USER_ID, TOUR_ID);

    expect(result.rows[0].event_date).toBeNull();
  });

  it('build は T6 のマスキング用に rep_history_visible を含む内部行を返す', async () => {
    const event = eventWithApplications();
    event.applications[0].repIdentity.historyVisible = false;
    prisma.event.findMany.mockResolvedValue([event]);

    const internal = await service.build(USER_ID, TOUR_ID);

    expect(internal.tour).toEqual(TOUR);
    expect(internal.rows[0].rep_history_visible).toBe(false);
  });

  it('buildMatrix の行に rep_history_visible は含めない（公開契約に無いキー）', async () => {
    prisma.event.findMany.mockResolvedValue([eventWithApplications()]);

    const result = await service.buildMatrix(USER_ID, TOUR_ID);

    expect(result.rows[0]).not.toHaveProperty('rep_history_visible');
  });
});
