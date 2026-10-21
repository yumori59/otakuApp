/**
 * クラウド環境（meigicho-prod / Supabase）の test@example.com に投入済みの
 * 架空ツアーデータ（STARLUME/MOONRIZE/AZURE PROJECT）を削除し、
 * TWICE の実際のツアー・公演情報（2023年 TWICE 5TH WORLD TOUR 'READY TO BE' 日本ドームツアー）
 * に置き換える。公演日は実際の興行記録として厳密ではなく目安（テストデータ用途）。
 * 既存の Identity "Yuya" (self) / "妹" / "友人A" と Tour "Test" はそのまま残す。
 *
 *   cd apps/api && \
 *     DATABASE_URL=$(gcloud secrets versions access latest --secret=database-url --project=meigicho-prod) \
 *     npx ts-node src/dev-seed/replace-with-twice.cli.ts
 */
import { PrismaService } from '../prisma/prisma.service';

const OWNER_ID = 'e6a8b0b1-7c00-435a-a817-8e8f317b12ae'; // test@example.com (meigicho-prod)
const IDENTITY_SELF_EXISTING = '01a01aca-32e2-7e56-8370-10a18f224693'; // 既存 "Yuya" (self)
const IDENTITY_SISTER = 'ecfa1361-fd3e-4d2f-9cc6-c0890211dde4'; // 既存 "妹"
const IDENTITY_FRIEND = '4563cf78-1c18-4b65-b8e9-57182d7ecf5a'; // 既存 "友人A"

// 削除対象: 前回投入した架空ツアー関連 (Tour 削除で Event/Application/Companion は cascade で消える)
const OLD_TOUR_IDS = [
  'ba4f74ac-204d-4e56-8776-8903076a464f', // STARLUME
  'afd0cde8-3786-48d8-b8c1-3de006ec7290', // MOONRIZE
  '0ecf7293-df21-40a6-b857-2100dc54e00a', // AZURE PROJECT
];
const OLD_MEMBERSHIP_IDS = [
  'c455007c-1a23-4813-b978-3a6be968ac7e', // STARLUME (self)
  'ec30d00f-020c-4c5c-922b-86d7843d63a0', // MOONRIZE (self)
  'a871a16a-9d34-4a9c-9d22-ec152eacc514', // STARLUME (sister)
  'dfd0bdb8-77f9-4354-b8c3-f5dcc199cbdb', // AZURE PROJECT (friend)
];

const TOUR_TWICE = 'fc19ccd7-0105-41cb-80e2-8cc1dde11e7c';

const MEMBERSHIP_SELF_TWICE = '84bd242c-b574-4088-84f8-1d66279e1a59';
const MEMBERSHIP_SISTER_TWICE = '4c5cd3c1-c2ef-4dd7-985c-3a49ba40e658';
const MEMBERSHIP_FRIEND_TWICE = '59826d85-a942-4c21-ab17-b0f744a5357b';

const EVENT_TOKYO_DOME = '8eb98db1-1cd7-4a5d-8137-45b54e00155d';
const EVENT_KYOCERA_OSAKA = '8fe75509-6d36-45fc-9503-b077ac05da6b';
const EVENT_PAYPAY_FUKUOKA = 'bd6ab48c-f70c-451e-9cfe-7fa5ffa94467';
const EVENT_VANTELIN_NAGOYA = 'b6ef7769-f9f7-46f2-bd2a-8904d5140120';

const APP_TOKYO_DOME = '8c82ca86-5b58-4790-925a-2b0f1f66afe0';
const APP_KYOCERA_OSAKA = 'c71fcf6f-4ae4-475f-a552-445f6aac680c';
const APP_PAYPAY_FUKUOKA = '1f75719f-35a6-4fc7-8305-f29ee30e98dc';
const APP_VANTELIN_NAGOYA = 'bf4fad88-902e-425d-9dce-ae8756de4abf';

const COMPANION_TOKYO_DOME = '781fde2a-6d2d-487c-94e9-035dcc8fc437';

async function main(): Promise<void> {
  const prisma = new PrismaService();
  await prisma.$connect();

  try {
    const owner = await prisma.user.findUnique({ where: { id: OWNER_ID } });
    if (!owner || owner.email !== 'test@example.com') {
      throw new Error(`想定外の接続先です。owner=${JSON.stringify(owner)}`);
    }

    const deletedTours = await prisma.tour.deleteMany({ where: { id: { in: OLD_TOUR_IDS } } });
    const deletedMemberships = await prisma.membership.deleteMany({
      where: { id: { in: OLD_MEMBERSHIP_IDS } },
    });
    process.stdout.write(
      `削除: tours=${deletedTours.count} memberships=${deletedMemberships.count}\n`,
    );

    await prisma.tour.upsert({
      where: { id: TOUR_TWICE },
      create: {
        id: TOUR_TWICE,
        ownerId: OWNER_ID,
        artistNameRaw: 'TWICE',
        name: "TWICE 5TH WORLD TOUR 'READY TO BE' in JAPAN",
      },
      update: {},
    });

    await prisma.membership.upsert({
      where: { id: MEMBERSHIP_SELF_TWICE },
      create: {
        id: MEMBERSHIP_SELF_TWICE,
        ownerId: OWNER_ID,
        identityId: IDENTITY_SELF_EXISTING,
        fanClubNameRaw: 'ONCE JAPAN',
        memberNo: '11223344',
        rank: 'レギュラー',
        renewalOn: new Date('2027-02-28'),
        feeYen: 4000,
        autoRenew: true,
      },
      update: {},
    });
    await prisma.membership.upsert({
      where: { id: MEMBERSHIP_SISTER_TWICE },
      create: {
        id: MEMBERSHIP_SISTER_TWICE,
        ownerId: OWNER_ID,
        identityId: IDENTITY_SISTER,
        fanClubNameRaw: 'ONCE JAPAN',
        memberNo: '22334455',
        rank: 'レギュラー',
        renewalOn: new Date('2027-02-28'),
        feeYen: 4000,
        autoRenew: false,
      },
      update: {},
    });
    await prisma.membership.upsert({
      where: { id: MEMBERSHIP_FRIEND_TWICE },
      create: {
        id: MEMBERSHIP_FRIEND_TWICE,
        ownerId: OWNER_ID,
        identityId: IDENTITY_FRIEND,
        fanClubNameRaw: 'ONCE JAPAN',
        memberNo: '33445566',
        rank: 'レギュラー',
        renewalOn: new Date('2026-12-31'),
        feeYen: 4000,
        autoRenew: false,
      },
      update: {},
    });

    const events: Array<{
      id: string;
      name: string;
      venueNameRaw: string;
      eventDate: string;
      startsAt: string;
    }> = [
      {
        id: EVENT_TOKYO_DOME,
        name: '東京公演',
        venueNameRaw: '東京ドーム',
        eventDate: '2023-10-10',
        startsAt: '2023-10-10T18:00:00+09:00',
      },
      {
        id: EVENT_KYOCERA_OSAKA,
        name: '大阪公演',
        venueNameRaw: '京セラドーム大阪',
        eventDate: '2023-10-14',
        startsAt: '2023-10-14T18:00:00+09:00',
      },
      {
        id: EVENT_PAYPAY_FUKUOKA,
        name: '福岡公演',
        venueNameRaw: '福岡PayPayドーム',
        eventDate: '2023-10-21',
        startsAt: '2023-10-21T18:00:00+09:00',
      },
      {
        id: EVENT_VANTELIN_NAGOYA,
        name: '名古屋公演',
        venueNameRaw: 'バンテリンドーム ナゴヤ',
        eventDate: '2023-10-28',
        startsAt: '2023-10-28T18:00:00+09:00',
      },
    ];
    for (const e of events) {
      await prisma.event.upsert({
        where: { id: e.id },
        create: {
          id: e.id,
          ownerId: OWNER_ID,
          tourId: TOUR_TWICE,
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
      repMembershipId: string;
      status: 'draft' | 'applied' | 'won' | 'lost' | 'cancelled';
      roundName: string;
      appliedOn: string;
      resultOn: string | null;
      seatRaw: string | null;
      ticketCount: number;
      priceYen: number | null;
    }> = [
      {
        id: APP_TOKYO_DOME,
        eventId: EVENT_TOKYO_DOME,
        repIdentityId: IDENTITY_SELF_EXISTING,
        repMembershipId: MEMBERSHIP_SELF_TWICE,
        status: 'won',
        roundName: 'FC先行',
        appliedOn: '2023-07-10',
        resultOn: '2023-08-01',
        seatRaw: 'アリーナ A-3-15',
        ticketCount: 2,
        priceYen: 15400,
      },
      {
        id: APP_KYOCERA_OSAKA,
        eventId: EVENT_KYOCERA_OSAKA,
        repIdentityId: IDENTITY_SELF_EXISTING,
        repMembershipId: MEMBERSHIP_SELF_TWICE,
        status: 'lost',
        roundName: 'FC先行',
        appliedOn: '2023-07-10',
        resultOn: '2023-08-01',
        seatRaw: null,
        ticketCount: 1,
        priceYen: 15400,
      },
      {
        id: APP_PAYPAY_FUKUOKA,
        eventId: EVENT_PAYPAY_FUKUOKA,
        repIdentityId: IDENTITY_SISTER,
        repMembershipId: MEMBERSHIP_SISTER_TWICE,
        status: 'won',
        roundName: '一般先行',
        appliedOn: '2023-08-15',
        resultOn: '2023-09-01',
        seatRaw: 'スタンド 2F-B-20',
        ticketCount: 1,
        priceYen: 15400,
      },
      {
        id: APP_VANTELIN_NAGOYA,
        eventId: EVENT_VANTELIN_NAGOYA,
        repIdentityId: IDENTITY_FRIEND,
        repMembershipId: MEMBERSHIP_FRIEND_TWICE,
        status: 'cancelled',
        roundName: '一般2次',
        appliedOn: '2023-08-20',
        resultOn: '2023-09-05',
        seatRaw: null,
        ticketCount: 1,
        priceYen: 15400,
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
      where: { id: COMPANION_TOKYO_DOME },
      create: {
        id: COMPANION_TOKYO_DOME,
        ownerId: OWNER_ID,
        applicationId: APP_TOKYO_DOME,
        identityId: IDENTITY_SISTER,
        displayName: '妹',
        position: 0,
      },
      update: {},
    });

    process.stdout.write('remote dev-seed: TWICE のデータに置き換えました\n');
  } finally {
    await prisma.$disconnect();
  }
}

void main().catch((error: unknown) => {
  process.stderr.write(`${String(error)}\n`);
  process.exitCode = 1;
});
