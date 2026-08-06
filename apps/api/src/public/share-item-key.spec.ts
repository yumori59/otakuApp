import {
  ITEM_KEY_LENGTH,
  ITEM_REV_LENGTH,
  handleEquals,
  shareItemKey,
  shareItemRev,
} from './share-item-key';

const TOKEN_HASH_A = 'a'.repeat(64);
const TOKEN_HASH_B = 'b'.repeat(64);
const APPLICATION_ID = '018f3c2a-cccc-7c90-9d2a-000000000001';
const OTHER_APPLICATION_ID = '018f3c2a-cccc-7c90-9d2a-000000000002';
const UPDATED_AT = new Date('2026-08-02T10:00:00.000Z');

/** base64url の文字種だけで構成されているか。 */
const BASE64URL_RE = /^[A-Za-z0-9_-]+$/;

describe('share-item-key', () => {
  describe('shareItemKey', () => {
    it('AC-SW-09 base64url 22 文字で、同じ入力なら決定的', () => {
      const key = shareItemKey(TOKEN_HASH_A, APPLICATION_ID);

      expect(key).toHaveLength(ITEM_KEY_LENGTH);
      expect(key).toMatch(BASE64URL_RE);
      expect(shareItemKey(TOKEN_HASH_A, APPLICATION_ID)).toBe(key);
    });

    it('AC-SW-09 item_key から application UUID を復元できない（部分文字列を含まない）', () => {
      const key = shareItemKey(TOKEN_HASH_A, APPLICATION_ID);

      expect(key).not.toContain(APPLICATION_ID);
      // UUID のどのセグメントも現れない
      for (const segment of APPLICATION_ID.split('-')) {
        expect(key).not.toContain(segment);
      }
      // base64url / hex デコードしても UUID にならない
      expect(Buffer.from(key, 'base64url').toString('utf8')).not.toContain(
        APPLICATION_ID.slice(0, 8),
      );
    });

    it('AC-SW-08 同じ application でも token_hash が違えば item_key が違う', () => {
      expect(shareItemKey(TOKEN_HASH_A, APPLICATION_ID)).not.toBe(
        shareItemKey(TOKEN_HASH_B, APPLICATION_ID),
      );
    });

    it('同じリンクでも application が違えば item_key が違う', () => {
      expect(shareItemKey(TOKEN_HASH_A, APPLICATION_ID)).not.toBe(
        shareItemKey(TOKEN_HASH_A, OTHER_APPLICATION_ID),
      );
    });
  });

  describe('shareItemRev', () => {
    it('AC-SW-09 base64url 16 文字で、同じ入力なら決定的', () => {
      const rev = shareItemRev(TOKEN_HASH_A, APPLICATION_ID, UPDATED_AT);

      expect(rev).toHaveLength(ITEM_REV_LENGTH);
      expect(rev).toMatch(BASE64URL_RE);
      expect(shareItemRev(TOKEN_HASH_A, APPLICATION_ID, UPDATED_AT)).toBe(rev);
    });

    it('AC-SW-09 rev から updated_at を復元できない', () => {
      const rev = shareItemRev(TOKEN_HASH_A, APPLICATION_ID, UPDATED_AT);
      const iso = UPDATED_AT.toISOString();

      expect(rev).not.toContain(iso);
      expect(rev).not.toContain(String(UPDATED_AT.getTime()));
      expect(rev).not.toContain(iso.slice(0, 10));
      expect(rev).not.toContain(APPLICATION_ID);
    });

    it('updated_at が 1ms でも違えば rev が変わる', () => {
      const rev = shareItemRev(TOKEN_HASH_A, APPLICATION_ID, UPDATED_AT);
      const next = shareItemRev(
        TOKEN_HASH_A,
        APPLICATION_ID,
        new Date(UPDATED_AT.getTime() + 1),
      );

      expect(next).not.toBe(rev);
    });

    it('item_key と rev は同じ入力でも一致しない（用途を混同できない）', () => {
      expect(shareItemRev(TOKEN_HASH_A, APPLICATION_ID, UPDATED_AT)).not.toBe(
        shareItemKey(TOKEN_HASH_A, APPLICATION_ID).slice(0, ITEM_REV_LENGTH),
      );
    });
  });

  describe('handleEquals', () => {
    it('一致すれば true', () => {
      expect(handleEquals('abcdef', 'abcdef')).toBe(true);
    });

    it('長さが違っても例外にせず false', () => {
      expect(handleEquals('abcdef', 'abc')).toBe(false);
      expect(handleEquals('abc', 'abcdef')).toBe(false);
    });

    it('文字列以外・空文字は false', () => {
      expect(handleEquals('abcdef', undefined)).toBe(false);
      expect(handleEquals('abcdef', null)).toBe(false);
      expect(handleEquals('abcdef', 123)).toBe(false);
      expect(handleEquals('abcdef', '')).toBe(false);
    });
  });
});
