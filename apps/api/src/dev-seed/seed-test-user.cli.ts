/**
 * ローカル開発 DB に test@example.com 用のそれっぽいダミーデータを投入する。
 * 全レコード固定 UUID で upsert するため、再実行しても重複しない。
 *
 *   cd apps/api && DATABASE_URL=postgres://meigicho:meigicho@localhost:5432/meigicho \
 *     npx ts-node src/dev-seed/seed-test-user.cli.ts
 */
import { PrismaService } from '../prisma/prisma.service';

const OWNER_ID = '991a0bd7-9136-4610-ba3c-767f49790eda'; // test@example.com

const IDENTITY_SELF = '944186ad-04b6-4609-82f9-ab83805d94c6';
const IDENTITY_SISTER = '195e9872-6932-40c6-be5f-d4c81fbc6199';
const IDENTITY_FRIEND = 'ced6d44f-424b-46bc-83a7-adfb35be7f88';

const MEMBERSHIP_SELF_STARLUME = '88f38cf2-ae52-4889-aae4-9cffccfbe7ea';
const MEMBERSHIP_SELF_MOONRIZE = 'fefc86b5-45f2-4397-a7e2-50b014b91ca2';
const MEMBERSHIP_SISTER_STARLUME = 'fa1bf65b-32ff-4536-a9b1-9bf4e3b0f8c9';
const MEMBERSHIP_FRIEND_AZURE = 'd84c1020-831c-48e5-ba02-d7963b880dd3';

const TOUR_STARLUME = '2c98442c-0014-44f7-b69d-c2cfcc4fe13d';
const TOUR_MOONRIZE = '03d0642e-6894-4852-8106-9ffc42b3eb38';
const TOUR_AZURE = '57b31f0a-7d5e-431f-8f71-b9447da5dbb7';

const EVENT_STARLUME_TOKYO = '06c193c6-7c6b-4136-be5e-2667d85dbc9b';
const EVENT_STARLUME_OSAKA = '6c687e6c-2cb7-461f-ae6d-0d82a2c58f15';
const EVENT_STARLUME_FUKUOKA = 'a9b53d99-6b52-4c65-a5d0-59ce91ebc1f9';
const EVENT_MOONRIZE_YOKOHAMA = 'cc9e4708-bcaa-49ac-bda8-5a7bb0b8a642';
const EVENT_AZURE_NAGOYA = '62614799-1fa7-48e3-8a39-7c5949e8a924';
const EVENT_AZURE_TOKYO2 = 'f7ee8304-eb7a-4aa6-84c7-2e828497316c';

const APP_STARLUME_TOKYO = '96cc3bd6-963b-4aee-92d1-dd37bc46c2ae';
const APP_STARLUME_OSAKA = 'bcec3e47-3c4f-4046-a490-bcfa5c86ac1e';
const APP_STARLUME_FUKUOKA = '18f51a14-2c26-4e15-afdf-7479cd2b989a';
const APP_MOONRIZE_YOKOHAMA = 'f38abe9f-32d7-4a50-b7e8-5e9a9b22fc75';
const APP_AZURE_NAGOYA = '7a2e1c4e-2a3b-4d5c-9e6f-1a2b3c4d5e6f';
const APP_AZURE_TOKYO2 = '8b3f2d5f-3b4c-5e6d-af70-2b3c4d5e6f70';

const COMPANION_STARLUME_TOKYO = '9c4a3e60-4c5d-6f7e-b081-3c4d5e6f7081';

async function main(): Promise<void> {
  const prisma = new PrismaService();
  await prisma.$connect();

  try {
    await prisma.identity.upsert({
      where: { id: IDENTITY_SELF },
      create: {
        id: IDENTITY_SELF,
        ownerId: OWNER_ID,
        displayName: '本人',
        relation: 'self',
        color: '#0017C1',
        joinedOn: new Date('2022-04-01'),
        historyVisible: true,
        sortOrder: 0,
      },
      update: {},
    });
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
        identityId: IDENTITY_SELF,
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
        identityId: IDENTITY_SELF,
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
        repIdentityId: IDENTITY_SELF,
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
        repIdentityId: IDENTITY_SELF,
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
        repIdentityId: IDENTITY_SELF,
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

    process.stdout.write('dev-seed: test@example.com にダミーデータを投入しました\n');
  } finally {
    await prisma.$disconnect();
  }
}

void main().catch((error: unknown) => {
  process.stderr.write(`${String(error)}\n`);
  process.exitCode = 1;
});
