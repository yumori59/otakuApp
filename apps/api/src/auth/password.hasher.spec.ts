import {
  SCRYPT_DEFAULT_PARAMS,
  ScryptPasswordHasher,
} from './password.hasher';

const PASSWORD = 'correct horse battery';

describe('ScryptPasswordHasher', () => {
  // 既定パラメータは 1 回あたり 100ms 程度かかるので、既定値の検証以外は軽い設定を使う
  const cheap = new ScryptPasswordHasher({ N: 1024, r: 8, p: 1 });

  it('AC-EP-02 既定は scrypt$N=32768,r=8,p=3$<salt>$<hash> 形式で平文を含まない', async () => {
    const hasher = new ScryptPasswordHasher();

    const stored = await hasher.hash(PASSWORD);

    expect(stored).toMatch(
      /^scrypt\$N=32768,r=8,p=3\$[A-Za-z0-9_-]+\$[A-Za-z0-9_-]+$/,
    );
    expect(stored).not.toContain(PASSWORD);
    await expect(hasher.verify(PASSWORD, stored)).resolves.toBe(true);
  });

  it('AC-EP-02 同じパスワードでも salt が異なるので毎回違う文字列になる', async () => {
    const first = await cheap.hash(PASSWORD);
    const second = await cheap.hash(PASSWORD);

    expect(first).not.toBe(second);
    await expect(cheap.verify(PASSWORD, first)).resolves.toBe(true);
    await expect(cheap.verify(PASSWORD, second)).resolves.toBe(true);
  });

  it('AC-EP-08 パスワードが違えば false', async () => {
    const stored = await cheap.hash(PASSWORD);

    await expect(cheap.verify('another password', stored)).resolves.toBe(false);
    await expect(cheap.verify('', stored)).resolves.toBe(false);
  });

  it('AC-EP-09 stored が null / 壊れていても例外を投げず false を返す（列挙耐性）', async () => {
    await expect(cheap.verify(PASSWORD, null)).resolves.toBe(false);
    await expect(cheap.verify(PASSWORD, '')).resolves.toBe(false);
    await expect(cheap.verify(PASSWORD, 'not-a-hash')).resolves.toBe(false);
    await expect(cheap.verify(PASSWORD, 'scrypt$N=x,r=y,p=z$aa$bb')).resolves.toBe(
      false,
    );
    await expect(
      cheap.verify(PASSWORD, 'argon2$N=1024,r=8,p=1$aa$bb'),
    ).resolves.toBe(false);
  });

  it('AC-EP-09 stored が null でも実際にハッシュ計算を行う（タイミング差を作らない）', async () => {
    const stored = await cheap.hash(PASSWORD);

    const elapsed = async (fn: () => Promise<unknown>) => {
      const started = process.hrtime.bigint();
      await fn();
      return Number(process.hrtime.bigint() - started) / 1e6;
    };

    const hit = await elapsed(() => cheap.verify(PASSWORD, stored));
    const miss = await elapsed(() => cheap.verify(PASSWORD, null));

    // ユーザー不在時に即 false を返す実装だと miss がほぼ 0ms になる
    expect(miss).toBeGreaterThan(hit / 10);
  });

  it('AC-EP-10 保存パラメータが現行既定と異なれば needsRehash が true', async () => {
    const hasher = new ScryptPasswordHasher();

    const legacy = await cheap.hash(PASSWORD);
    const current = await hasher.hash(PASSWORD);

    expect(hasher.needsRehash(legacy)).toBe(true);
    expect(hasher.needsRehash(current)).toBe(false);
  });

  it('AC-EP-10 壊れた stored は needsRehash が true', () => {
    const hasher = new ScryptPasswordHasher();

    expect(hasher.needsRehash('not-a-hash')).toBe(true);
    expect(hasher.needsRehash('')).toBe(true);
  });

  it('AC-EP-10 旧パラメータで作られたハッシュも verify できる', async () => {
    const legacy = await cheap.hash(PASSWORD);

    await expect(
      new ScryptPasswordHasher().verify(PASSWORD, legacy),
    ).resolves.toBe(true);
  });

  it('既定パラメータは plan.md §4.3 の値', () => {
    expect(SCRYPT_DEFAULT_PARAMS).toEqual({ N: 32768, r: 8, p: 3 });
  });
});
