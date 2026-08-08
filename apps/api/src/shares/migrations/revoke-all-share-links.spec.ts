import {
  REVOKE_ALL_SHARE_LINKS_SQL,
  revokedAtAfterMigration,
  shareLinksToRevoke,
} from './revoke-all-share-links';

describe('revoke-all-share-links (share-account-invites 移行 / api-contract-delta.md §0.5)', () => {
  const NOW = new Date('2026-08-07T00:00:00.000Z');
  const ALREADY = new Date('2026-01-01T00:00:00.000Z');

  it('AC-SI-60 SQL は revoked_at が NULL の share_links を全件失効させる', () => {
    expect(REVOKE_ALL_SHARE_LINKS_SQL).toBe(
      'update share_links set revoked_at = now() where revoked_at is null',
    );
  });

  it('AC-SI-60 未失効の行は now() で失効する', () => {
    expect(revokedAtAfterMigration(null, NOW)).toEqual(NOW);
  });

  it('AC-SI-62 既に失効している行の revoked_at は上書きしない（冪等）', () => {
    expect(revokedAtAfterMigration(ALREADY, NOW)).toEqual(ALREADY);
  });

  it('AC-SI-62 2 回適用しても結果が変わらない（冪等）', () => {
    const once = revokedAtAfterMigration(null, NOW);
    const twice = revokedAtAfterMigration(once, new Date('2026-09-01T00:00:00.000Z'));
    expect(twice).toEqual(NOW);
  });

  it('AC-SI-62 対象行は revoked_at IS NULL のものだけ', () => {
    const rows = [
      { id: 'a', revokedAt: null },
      { id: 'b', revokedAt: ALREADY },
      { id: 'c', revokedAt: null },
    ];
    expect(shareLinksToRevoke(rows).map((row) => row.id)).toEqual(['a', 'c']);
    // 2 回目は対象ゼロ
    const after = rows.map((row) => ({
      ...row,
      revokedAt: revokedAtAfterMigration(row.revokedAt, NOW),
    }));
    expect(shareLinksToRevoke(after)).toEqual([]);
  });
});
