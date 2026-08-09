import { ShareLink, ShareRecipient } from '@prisma/client';
import {
  InboxRow,
  ShareRecipientAccessService,
} from '../share-recipient-access.service';
import { ListInboxUseCase } from './list-inbox.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const OWNER_ID = '018f3c2a-0000-7c90-9d2a-000000000009';
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const NOW = new Date('2026-08-02T10:00:00.000Z');

function shareLink(overrides: Partial<ShareLink> = {}): ShareLink {
  return {
    id: SHARE_ID,
    ownerId: OWNER_ID,
    scopeType: 'tour',
    scopeId: TOUR_ID,
    tokenHash: 'a'.repeat(64),
    permission: 'write',
    maskMemberNo: true,
    expiresAt: new Date('2026-08-31T00:00:00.000Z'),
    revokedAt: null,
    viewCount: 0,
    lastViewedAt: null,
    editCount: 0,
    lastEditedAt: null,
    createdAt: new Date('2026-07-01T00:00:00.000Z'),
    updatedAt: new Date('2026-07-01T00:00:00.000Z'),
    ...overrides,
  } as ShareLink;
}

function inboxRow(overrides: {
  recipient?: Partial<ShareRecipient>;
  link?: Partial<ShareLink>;
} = {}): InboxRow {
  const link = shareLink(overrides.link);
  return {
    id: '018f3c2a-2222-7c90-9d2a-000000000001',
    shareLinkId: link.id,
    accountId: 'ACC-7C1D02',
    userId: USER_ID,
    hiddenAt: null,
    lastViewedAt: null,
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
    ...overrides.recipient,
    shareLink: {
      ...link,
      owner: {
        profile: { accountId: 'ACC-7C1D02', displayName: 'みお' },
      },
    },
  } as unknown as InboxRow;
}

describe('ListInboxUseCase', () => {
  let access: {
    listInboxRows: jest.Mock;
    resolveTourNames: jest.Mock;
  };
  let useCase: ListInboxUseCase;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    access = {
      listInboxRows: jest.fn().mockResolvedValue([]),
      resolveTourNames: jest.fn().mockResolvedValue(new Map()),
    };
    useCase = new ListInboxUseCase(
      access as unknown as ShareRecipientAccessService,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('AC-SI-40 招待 0 件でも 200 相当の空配列を返す', async () => {
    const items = await useCase.execute(USER_ID);
    expect(items).toEqual([]);
    expect(access.listInboxRows).toHaveBeenCalledWith(USER_ID, NOW);
  });

  it('AC-SI-41 契約どおりのキーだけを持つ item を返す（tour）', async () => {
    access.listInboxRows.mockResolvedValue([inboxRow()]);
    access.resolveTourNames.mockResolvedValue(
      new Map([[TOUR_ID, 'STELLARIS LIVE TOUR 2026']]),
    );

    const items = await useCase.execute(USER_ID);

    expect(items).toEqual([
      {
        share_id: SHARE_ID,
        scope_type: 'tour',
        scope_name: 'STELLARIS LIVE TOUR 2026',
        permission: 'write',
        owner: { account_id: 'ACC-7C1D02', display_name: 'みお' },
        invited_at: '2026-08-01T00:00:00.000Z',
        expires_at: '2026-08-31T00:00:00.000Z',
        unread: true,
      },
    ]);
  });

  it('AC-SI-45 あってはならないキーが混入していない（あるべきキーの列挙ではなく不在を検証）', async () => {
    access.listInboxRows.mockResolvedValue([inboxRow()]);

    const items = await useCase.execute(USER_ID);
    const json = JSON.stringify(items);

    for (const forbidden of [
      'token',
      'token_hash',
      'scope_id',
      'owner_id',
      'ownerId',
      'member_no',
    ]) {
      expect(json).not.toContain(forbidden);
    }
    expect(json).not.toContain(OWNER_ID);
  });

  it('scope_type = identity_summary は固定文言を scope_name にする', async () => {
    access.listInboxRows.mockResolvedValue([
      inboxRow({ link: { scopeType: 'identity_summary', scopeId: null } }),
    ]);

    const items = await useCase.execute(USER_ID);

    expect(items[0].scope_name).toBe('名義の申込サマリー');
    expect(access.resolveTourNames).toHaveBeenCalledWith([]);
  });

  it('AC-SI-46 last_viewed_at が null なら unread:true', async () => {
    access.listInboxRows.mockResolvedValue([
      inboxRow({ recipient: { lastViewedAt: null } }),
    ]);

    const items = await useCase.execute(USER_ID);
    expect(items[0].unread).toBe(true);
  });

  it('AC-SI-46 last_viewed_at が非null かつ last_edited_at が null（未編集）なら unread:false', async () => {
    access.listInboxRows.mockResolvedValue([
      inboxRow({
        recipient: { lastViewedAt: new Date('2026-07-02T00:00:00.000Z') },
        link: {
          updatedAt: new Date('2026-08-02T09:00:00.000Z'),
          lastEditedAt: null,
        },
      }),
    ]);

    const items = await useCase.execute(USER_ID);
    expect(items[0].unread).toBe(false);
  });

  it('AC-SI-46 last_viewed_at が last_edited_at より前なら unread:true（見た後に編集された）', async () => {
    access.listInboxRows.mockResolvedValue([
      inboxRow({
        recipient: { lastViewedAt: new Date('2026-07-01T00:00:00.000Z') },
        link: { lastEditedAt: new Date('2026-07-02T00:00:00.000Z') },
      }),
    ]);

    const items = await useCase.execute(USER_ID);
    expect(items[0].unread).toBe(true);
  });

  it('AC-SI-46 last_viewed_at が last_edited_at 以上なら unread:false', async () => {
    access.listInboxRows.mockResolvedValue([
      inboxRow({
        recipient: { lastViewedAt: new Date('2026-07-02T00:00:00.000Z') },
        link: { lastEditedAt: new Date('2026-07-01T00:00:00.000Z') },
      }),
    ]);

    const items = await useCase.execute(USER_ID);
    expect(items[0].unread).toBe(false);
  });

  it('AC-SI-46-repro 他の招待者の閲覧で updated_at が進んでも、自分の last_viewed_at 済みなら unread は false のまま（再発防止）', async () => {
    // 招待者 A が共有を開いた結果（resolve-share.use-case の recordView）:
    // view_count が加算され share_links.updated_at が進むが、lastEditedAt は変わらない。
    access.listInboxRows.mockResolvedValue([
      inboxRow({
        recipient: { lastViewedAt: new Date('2026-08-01T12:00:00.000Z') },
        link: {
          viewCount: 5,
          updatedAt: new Date('2026-08-02T09:59:00.000Z'), // A の閲覧直後（自分の閲覧より後）
          lastEditedAt: null,
        },
      }),
    ]);

    const items = await useCase.execute(USER_ID);
    expect(items[0].unread).toBe(false);
  });

  it('AC-SI-46-repro オーナーが実際に編集した後は、既に見ていた招待者の unread が true に戻る', async () => {
    access.listInboxRows.mockResolvedValue([
      inboxRow({
        recipient: { lastViewedAt: new Date('2026-08-01T12:00:00.000Z') },
        link: {
          editCount: 1,
          lastEditedAt: new Date('2026-08-02T08:00:00.000Z'), // 自分の閲覧より後に編集された
        },
      }),
    ]);

    const items = await useCase.execute(USER_ID);
    expect(items[0].unread).toBe(true);
  });

  it('絞り込み・並びは ShareRecipientAccessService に委譲する（AC-SI-42〜44/47）', async () => {
    await useCase.execute(USER_ID);
    expect(access.listInboxRows).toHaveBeenCalledTimes(1);
    expect(access.listInboxRows).toHaveBeenCalledWith(USER_ID, NOW);
  });
});
