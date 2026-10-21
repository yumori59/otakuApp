/**
 * クラウド環境（meigicho-prod / Supabase）の test@example.com に
 * それっぽいダミーデータを追加投入する。dev/staging 環境が別建てで存在しないため、
 * 唯一のクラウド DB に対して実行する（ユーザー合意済み）。
 * 既存の Identity "Yuya" (self) / Tour "Test" はそのまま残し、追加データのみ upsert する。
 * 全レコード固定 UUID で upsert するため、再実行しても重複しない。
 *
 *   cd apps/api && \
 *     DATABASE_URL=$(gcloud secrets versions access latest --secret=database-url --project=meigicho-prod) \
 *     npx ts-node src/dev-seed/seed-remote-test-user.cli.ts
 */
import { PrismaService } from '../prisma/prisma.service';

const OWNER_ID = 'e6a8b0b1-7c00-435a-a817-8e8f317b12ae'; // test@example.com (meigicho-prod)
const IDENTITY_SELF_EXISTING = '01a01aca-32e2-7e56-8370-10a18f224693'; // 既存 "Yuya" (self)

const IDENTITY_SISTER = 'ecfa1361-fd3e-4d2f-9cc6-c0890211dde4';
const IDENTITY_FRIEND = '4563cf78-1c18-4b65-b8e9-57182d7ecf5a';

const MEMBERSHIP_SELF_STARLUME = 'c455007c-1a23-4813-b978-3a6be968ac7e';
const MEMBERSHIP_SELF_MOONRIZE = 'ec30d00f-020c-4c5c-922b-86d7843d63a0';
const MEMBERSHIP_SISTER_STARLUME = 'a871a16a-9d34-4a9c-9d22-ec152eacc514';
const MEMBERSHIP_FRIEND_AZURE = 'dfd0bdb8-77f9-4354-b8c3-f5dcc199cbdb';

const TOUR_STARLUME = 'ba4f74ac-204d-4e56-8776-8903076a464f';
const TOUR_MOONRIZE = 'afd0cde8-3786-48d8-b8c1-3de006ec7290';
const TOUR_AZURE = '0ecf7293-df21-40a6-b857-2100dc54e00a';

const EVENT_STARLUME_TOKYO = 'ed0d8fcc-361d-4a3a-94e2-b48e399ac336';
const EVENT_STARLUME_OSAKA = 'df5351fb-203f-403c-8aa3-dd5b88e5154b';
const EVENT_STARLUME_FUKUOKA = 'afe0db06-8304-4d9f-ad72-d702727b862f';
const EVENT_MOONRIZE_YOKOHAMA = 'a0aa681c-cec2-46b3-9a85-d96f17b9472f';
const EVENT_AZURE_NAGOYA = 'cb36f730-0844-41d5-9686-27f422bf29be';
const EVENT_AZURE_TOKYO2 = '620bf379-5158-4d01-ba77-ce16077ed5b8';

const APP_STARLUME_TOKYO = 'd0913231-00fc-4795-a51b-76f76c104b15';
const APP_STARLUME_OSAKA = '3ce0c019-ddb7-4d2e-895d-2658d57d193e';
const APP_STARLUME_FUKUOKA = '3fbc7a46-c0cf-4b8a-a37b-2bf87ec8c4c0';
const APP_MOONRIZE_YOKOHAMA = 'f0d31366-9470-4f88-96a8-35a0ce89ef68';
const APP_AZURE_NAGOYA = 'b634e6e9-45a4-4f2a-8ace-ea16de02e944';
const APP_AZURE_TOKYO2 = '8ac29b13-02a4-4cb0-b6d7-577e48c77283';

const COMPANION_STARLUME_TOKYO = '4458c116-a704-4add-9ad7-775b7d7596ab';

async function main(): Promise<void> {
  const prisma = new PrismaService();
  await prisma.$connect();

  try {
    const owner = await prisma.user.findUnique({ where: { id: OWNER_ID } });
    if (!owner || owner.email !== 'test@example.com') {
      throw new Error(`想定外の接続先です。owner=${JSON.stringify(owner)}`);
    }

    await prisma.identity.upsert({
      where: { id: IDENTITY_SISTER },
      create: {
        id: IDENTITY_SISTER,
        ownerId: OWNER_ID,
        displayName: '妹',
        relation: 'family',
        color: '#FF6B9D',
        joinedOn: new Date('2023-01-15'),
        historyVisible: false,
        sortOrder: 1,
      },
      update: {},
    });
    await prisma.identity.upsert({
      where: { id: IDENTITY_FRIEND },
      create: {
        id: IDENTITY_FRIEND,
        ownerId: OWNER_ID,
        displayName: '友人A',
        relation: 'friend',
        color: '#34C759',
        joinedOn: new Date('2024-06-01'),
        historyVisible: false,
        sortOrder: 2,
      },
      update: {},
    });

    await prisma.membership.upsert({
      where: { id: MEMBERSHIP_SELF_STARLUME },
      create: {
        id: MEMBERSHIP_SELF_STARLUME,
        ownerId: OWNER_ID,
        identityId: IDENTITY_SELF_EXISTING,
        fanClubNameRaw: 'STARLUME オフィシャルファンクラブ',
        memberNo: '12345678',
        rank: 'プラチナ',
        renewalOn: new Date('2027-03-31'),
        feeYen: 5500,
        autoRenew: true,
      },
      update: {},
    });
    await prisma.membership.upsert({
      where: { id: MEMBERSHIP_SELF_MOONRIZE },
      create: {
        id: MEMBERSHIP_SELF_MOONRIZE,
        ownerId: OWNER_ID,
        identityId: IDENTITY_SELF_EXISTING,
        fanClubNameRaw: 'MOONRIZE FC',
        memberNo: '87654321',
        rank: 'レギュラー',
        renewalOn: new Date('2026-12-31'),
        feeYen: 4000,
        autoRenew: false,
      },
      update: {},
    });
    await prisma.membership.upsert({
      where: { id: MEMBERSHIP_SISTER_STARLUME },
      create: {
        id: MEMBERSHIP_SISTER_STARLUME,
        ownerId: OWNER_ID,
        identityId: IDENTITY_SISTER,
        fanClubNameRaw: 'STARLUME オフィシャルファンクラブ',
        memberNo: '23456789',
        rank: 'レギュラー',
        renewalOn: new Date('2027-01-31'),
        feeYen: 5500,
        autoRenew: true,
      },
      update: {},
    });
    await prisma.membership.upsert({
      where: { id: MEMBERSHIP_FRIEND_AZURE },
      create: {
        id: MEMBERSHIP_FRIEND_AZURE,
        ownerId: OWNER_ID,
        identityId: IDENTITY_FRIEND,
        fanClubNameRaw: 'AZURE PROJECT FC',
        memberNo: '34567890',
        rank: 'レギュラー',
        renewalOn: new Date('2026-11-30'),
        feeYen: 3500,
        autoRenew: false,
      },
      update: {},
    });

    await prisma.tour.upsert({
      where: { id: TOUR_STARLUME },
      create: {
        id: TOUR_STARLUME,
        ownerId: OWNER_ID,
        artistNameRaw: 'STARLUME',
        name: 'STARLUME LIVE TOUR 2026 -Nova-',
      },
      update: {},
    });
    await prisma.tour.upsert({
      where: { id: TOUR_MOONRIZE },
      create: {
        id: TOUR_MOONRIZE,
        ownerId: OWNER_ID,
        artistNameRaw: 'MOONRIZE',
        name: 'MOONRIZE 5th Anniversary Live',
      },
      update: {},
    });
    await prisma.tour.upsert({
      where: { id: TOUR_AZURE },
      create: {
        id: TOUR_AZURE,
        ownerId: OWNER_ID,
        artistNameRaw: 'AZURE PROJECT',
        name: 'AZURE PROJECT ONEMAN 2026',
      },
      update: {},
    });

    const events: Array<{
      id: string;
      tourId: string;
      name: string;
      venueNameRaw: string;
      eventDate: string;
      startsAt: string;
    }> = [
      {
        id: EVENT_STARLUME_TOKYO,
        tourId: TOUR_STARLUME,
        name: '東京公演 Day1',
        venueNameRaw: '東京ガーデンシアター',
        eventDate: '2026-09-15',
        startsAt: '2026-09-15T17:00:00+09:00',
      },
      {
        id: EVENT_STARLUME_OSAKA,
        tourId: TOUR_STARLUME,
        name: '大阪公演',
        venueNameRaw: '大阪城ホール',
        eventDate: '2026-09-20',
        startsAt: '2026-09-20T17:00:00+09:00',
      },
      {
        id: EVENT_STARLUME_FUKUOKA,
        tourId: TOUR_STARLUME,
        name: '福岡公演',
        venueNameRaw: '福岡サンパレス',
        eventDate: '2026-09-27',
        startsAt: '2026-09-27T17:00:00+09:00',
      },
      {
        id: EVENT_MOONRIZE_YOKOHAMA,
        tourId: TOUR_MOONRIZE,
        name: '横浜公演',
        venueNameRaw: 'みなとみらい大ホール',
        eventDate: '2026-10-10',
        startsAt: '2026-10-10T18:00:00+09:00',
      },
      {
        id: EVENT_AZURE_NAGOYA,
        tourId: TOUR_AZURE,
        name: '名古屋公演',
        venueNameRaw: '日本ガイシホール',
        eventDate: '2026-11-03',
        startsAt: '2026-11-03T17:30:00+09:00',
      },
      {
        id: EVENT_AZURE_TOKYO2,
        tourId: TOUR_AZURE,
        name: '東京追加公演',
        venueNameRaw: '有明アリーナ',
        eventDate: '2026-11-15',
        startsAt: '2026-11-15T17:30:00+09:00',
      },
    ];
    for (const e of events) {
      await prisma.event.upsert({
        where: { id: e.id },
        create: {
          id: e.id,
          ownerId: OWNER_ID,
          tourId: e.tourId,
          name: e.name,
          venueNameRaw: e.venueNameRaw,
          eventDate: new Date(e.eventDate),
          startsAt: new Date(e.startsAt),
        },
        update: {},
      });
    }

    const applications: Array<{
      id: string;
      eventId: string;
      repIdentityId: string;
      repMembershipId: string | null;
      status: 'draft' | 'applied' | 'won' | 'lost' | 'cancelled';
      roundName: string;
      appliedOn: string;
      resultOn: string | null;
      seatRaw: string | null;
      ticketCount: number;
      priceYen: number | null;
    }> = [
      {
        id: APP_STARLUME_TOKYO,
        eventId: EVENT_STARLUME_TOKYO,
        repIdentityId: IDENTITY_SELF_EXISTING,
        repMembershipId: MEMBERSHIP_SELF_STARLUME,
        status: 'won',
        roundName: 'FC先行1次',
        appliedOn: '2026-07-01',
        resultOn: '2026-07-20',
        seatRaw: 'アリーナ B-12-34',
        ticketCount: 2,
        priceYen: 9800,
      },
      {
        id: APP_STARLUME_OSAKA,
        eventId: EVENT_STARLUME_OSAKA,
        repIdentityId: IDENTITY_SELF_EXISTING,
        repMembershipId: MEMBERSHIP_SELF_STARLUME,
        status: 'lost',
        roundName: 'FC先行1次',
        appliedOn: '2026-07-01',
        resultOn: '2026-07-20',
        seatRaw: null,
        ticketCount: 1,
        priceYen: 9800,
      },
      {
        id: APP_STARLUME_FUKUOKA,
        eventId: EVENT_STARLUME_FUKUOKA,
        repIdentityId: IDENTITY_SISTER,
        repMembershipId: MEMBERSHIP_SISTER_STARLUME,
        status: 'applied',
        roundName: 'FC先行2次',
        appliedOn: '2026-08-05',
        resultOn: null,
        seatRaw: null,
        ticketCount: 1,
        priceYen: 9800,
      },
      {
        id: APP_MOONRIZE_YOKOHAMA,
        eventId: EVENT_MOONRIZE_YOKOHAMA,
        repIdentityId: IDENTITY_SELF_EXISTING,
        repMembershipId: MEMBERSHIP_SELF_MOONRIZE,
        status: 'draft',
        roundName: '一般先行',
        appliedOn: '2026-08-20',
        resultOn: null,
        seatRaw: null,
        ticketCount: 1,
        priceYen: 8500,
      },
      {
        id: APP_AZURE_NAGOYA,
        eventId: EVENT_AZURE_NAGOYA,
        repIdentityId: IDENTITY_FRIEND,
        repMembershipId: MEMBERSHIP_FRIEND_AZURE,
        status: 'won',
        roundName: 'FC先行',
        appliedOn: '2026-09-01',
        resultOn: '2026-09-15',
        seatRaw: 'スタンド 3F-C-8',
        ticketCount: 1,
        priceYen: 7500,
      },
      {
        id: APP_AZURE_TOKYO2,
        eventId: EVENT_AZURE_TOKYO2,
        repIdentityId: IDENTITY_FRIEND,
        repMembershipId: MEMBERSHIP_FRIEND_AZURE,
        status: 'cancelled',
        roundName: '一般2次',
        appliedOn: '2026-09-10',
        resultOn: '2026-09-25',
        seatRaw: null,
        ticketCount: 1,
        priceYen: 7500,
      },
    ];
    for (const a of applications) {
      await prisma.application.upsert({
        where: { id: a.id },
        create: {
          id: a.id,
          ownerId: OWNER_ID,
          eventId: a.eventId,
          repIdentityId: a.repIdentityId,
          repMembershipId: a.repMembershipId,
          status: a.status,
          roundName: a.roundName,
          appliedOn: new Date(a.appliedOn),
          resultOn: a.resultOn ? new Date(a.resultOn) : null,
          seatRaw: a.seatRaw,
          ticketCount: a.ticketCount,
          priceYen: a.priceYen,
        },
        update: {},
      });
    }

    await prisma.applicationCompanion.upsert({
      where: { id: COMPANION_STARLUME_TOKYO },
      create: {
        id: COMPANION_STARLUME_TOKYO,
        ownerId: OWNER_ID,
        applicationId: APP_STARLUME_TOKYO,
        identityId: IDENTITY_SISTER,
        displayName: '妹',
        position: 0,
      },
      update: {},
    });

    process.stdout.write('remote dev-seed: test@example.com にダミーデータを投入しました\n');
  } finally {
    await prisma.$disconnect();
  }
}

void main().catch((error: unknown) => {
  process.stderr.write(`${String(error)}\n`);
  process.exitCode = 1;
});
