import { ShareLink } from '@prisma/client';
import {
  toShareCreatedResponse,
  toShareListItem,
  shareUrl,
} from './shares.presenter';

const NOW = new Date('2026-08-02T10:00:00.000Z');
const SHARE_ID = '018f3c2a-1111-7c90-9d2a-000000000001';
const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const TOUR_ID = '018f3c2a-dddd-7c90-9d2a-000000000001';
const RAW_TOKEN = 'raw-opaque-share-token';

function shareRow(overrides: Partial<ShareLink> = {}): ShareLink {
  return {
    id: SHARE_ID,
    ownerId: USER_ID,
    scopeType: 'tour',
    scopeId: TOUR_ID,
    tokenHash: 'a'.repeat(64),
    permission: 'read',
    maskMemberNo: true,
    expiresAt: new Date('2026-08-31T00:00:00.000Z'),
    revokedAt: null,
    viewCount: 3,
    lastViewedAt: new Date('2026-08-02T10:00:00.000Z'),
    editCount: 2,
    lastEditedAt: new Date('2026-08-02T11:30:00.000Z'),
    createdAt: new Date('2026-08-01T00:00:00.000Z'),
    updatedAt: new Date('2026-08-01T00:00:00.000Z'),
    ...overrides,
  } as ShareLink;
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

describe('shares.presenter', () => {
  describe('toShareListItem', () => {
    it('AC-SH-09 レスポンスに token / token_hash キーが存在しない (FR-SH-6)', () => {
      const item = toShareListItem(shareRow(), 'STELLARIS LIVE TOUR 2026', NOW);

      const keys = collectKeys(item);
      expect(keys).not.toContain('token');
      expect(keys).not.toContain('token_hash');
      expect(keys).not.toContain('tokenHash');
      expect(JSON.stringify(item)).not.toContain('token');
      expect(JSON.stringify(item)).not.toContain(shareRow().tokenHash);
    });

    it('AC-SH-09 契約どおりのキーだけを返す', () => {
      const item = toShareListItem(shareRow(), 'STELLARIS LIVE TOUR 2026', NOW);

      expect(Object.keys(item).sort()).toEqual(
        [
          'id',
          'scope_type',
          'scope_id',
          'scope_name',
          'permission',
          'mask_member_no',
          'expires_at',
          'revoked_at',
          'view_count',
          'last_viewed_at',
          'edit_count',
          'last_edited_at',
          'created_at',
          'is_active',
        ].sort(),
      );
      expect(item).toMatchObject({
        id: SHARE_ID,
        scope_type: 'tour',
        scope_id: TOUR_ID,
        scope_name: 'STELLARIS LIVE TOUR 2026',
        permission: 'read',
        mask_member_no: true,
        expires_at: '2026-08-31T00:00:00.000Z',
        revoked_at: null,
        view_count: 3,
        last_viewed_at: '2026-08-02T10:00:00.000Z',
        edit_count: 2,
        last_edited_at: '2026-08-02T11:30:00.000Z',
        created_at: '2026-08-01T00:00:00.000Z',
        is_active: true,
      });
    });

    it('AC-SW-23 未編集のリンクは edit_count:0 / last_edited_at:null', () => {
      const item = toShareListItem(
        shareRow({ editCount: 0, lastEditedAt: null }),
        null,
        NOW,
      );

      expect(item.edit_count).toBe(0);
      expect(item.last_edited_at).toBeNull();
    });

    it('owner_id は含めない (BE-4)', () => {
      const item = toShareListItem(shareRow(), null, NOW);
      expect(collectKeys(item)).not.toContain('owner_id');
      expect(JSON.stringify(item)).not.toContain(USER_ID);
    });

    it('is_active: revoked_at があれば false', () => {
      const item = toShareListItem(
        shareRow({ revokedAt: new Date('2026-08-01T12:00:00.000Z') }),
        null,
        NOW,
      );
      expect(item.is_active).toBe(false);
      expect(item.revoked_at).toBe('2026-08-01T12:00:00.000Z');
    });

    it('is_active: expires_at が now ちょうどなら false（E-8）', () => {
      const item = toShareListItem(shareRow({ expiresAt: NOW }), null, NOW);
      expect(item.is_active).toBe(false);
    });

    it('is_active: expires_at が null なら true', () => {
      const item = toShareListItem(shareRow({ expiresAt: null }), null, NOW);
      expect(item.is_active).toBe(true);
      expect(item.expires_at).toBeNull();
    });

    it('identity_summary の scope_name は null', () => {
      const item = toShareListItem(
        shareRow({ scopeType: 'identity_summary', scopeId: null }),
        null,
        NOW,
      );
      expect(item.scope_id).toBeNull();
      expect(item.scope_name).toBeNull();
    });
  });

  describe('toShareCreatedResponse', () => {
    it('AC-SH-01 生トークンと URL を返す（発行時のみ）', () => {
      const res = toShareCreatedResponse(
        shareRow(),
        RAW_TOKEN,
        'https://share.example.com',
      );

      expect(res.token).toBe(RAW_TOKEN);
      expect(res.url).toBe(`https://share.example.com/s/${RAW_TOKEN}`);
      expect(Object.keys(res).sort()).toEqual(
        [
          'id',
          'token',
          'url',
          'scope_type',
          'scope_id',
          'permission',
          'mask_member_no',
          'expires_at',
          'created_at',
        ].sort(),
      );
    });

    it('token_hash / owner_id は返さない', () => {
      const res = toShareCreatedResponse(
        shareRow(),
        RAW_TOKEN,
        'https://share.example.com',
      );
      const keys = collectKeys(res);
      expect(keys).not.toContain('token_hash');
      expect(keys).not.toContain('owner_id');
      expect(JSON.stringify(res)).not.toContain(shareRow().tokenHash);
      expect(JSON.stringify(res)).not.toContain(USER_ID);
    });
  });

  describe('shareUrl', () => {
    it('SHARE_BASE_URL の末尾スラッシュを重複させない', () => {
      expect(shareUrl('https://share.example.com/', 'abc')).toBe(
        'https://share.example.com/s/abc',
      );
      expect(shareUrl('https://share.example.com', 'abc')).toBe(
        'https://share.example.com/s/abc',
      );
    });
  });
});
