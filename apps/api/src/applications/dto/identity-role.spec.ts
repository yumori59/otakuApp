import {
  DEFAULT_IDENTITY_ROLE,
  IDENTITY_ROLES,
  normalizeRepresentativeName,
  resolveRoleOnCreate,
  resolveRoleOnUpdate,
} from './identity-role';

describe('identity-role', () => {
  it('IDENTITY_ROLES は representative / companion のみ', () => {
    expect([...IDENTITY_ROLES]).toEqual(['representative', 'companion']);
    expect(DEFAULT_IDENTITY_ROLE).toBe('representative');
  });

  describe('normalizeRepresentativeName', () => {
    it('trim する', () => {
      expect(normalizeRepresentativeName('  山田  ')).toBe('山田');
    });
    it('空文字・空白のみ・null・undefined は null', () => {
      expect(normalizeRepresentativeName('')).toBeNull();
      expect(normalizeRepresentativeName('   ')).toBeNull();
      expect(normalizeRepresentativeName(null)).toBeNull();
      expect(normalizeRepresentativeName(undefined)).toBeNull();
    });
  });

  describe('resolveRoleOnCreate', () => {
    it('role 省略は representative・name は null', () => {
      expect(resolveRoleOnCreate(undefined, '山田')).toEqual({
        identityRole: 'representative',
        representativeName: null,
      });
    });
    it('representative のとき name は null に正規化', () => {
      expect(resolveRoleOnCreate('representative', '山田')).toEqual({
        identityRole: 'representative',
        representativeName: null,
      });
    });
    it('companion のとき name は trim して保持、空は null', () => {
      expect(resolveRoleOnCreate('companion', ' 山田 ')).toEqual({
        identityRole: 'companion',
        representativeName: '山田',
      });
      expect(resolveRoleOnCreate('companion', '  ')).toEqual({
        identityRole: 'companion',
        representativeName: null,
      });
      expect(resolveRoleOnCreate('companion', undefined)).toEqual({
        identityRole: 'companion',
        representativeName: null,
      });
    });
  });

  describe('resolveRoleOnUpdate', () => {
    it('どちらも未指定なら何も変えない', () => {
      expect(resolveRoleOnUpdate({}, 'companion')).toEqual({});
    });
    it('role を representative にしたら name も null', () => {
      expect(
        resolveRoleOnUpdate({ identity_role: 'representative' }, 'companion'),
      ).toEqual({ identityRole: 'representative', representativeName: null });
    });
    it('role=representative と name を同時に送っても name は null', () => {
      expect(
        resolveRoleOnUpdate(
          { identity_role: 'representative', representative_name: '山田' },
          'companion',
        ),
      ).toEqual({ identityRole: 'representative', representativeName: null });
    });
    it('role を companion にするだけなら name には触れない', () => {
      expect(
        resolveRoleOnUpdate({ identity_role: 'companion' }, 'representative'),
      ).toEqual({ identityRole: 'companion' });
    });
    it('role=companion と name 同時指定は trim 済み name も更新', () => {
      expect(
        resolveRoleOnUpdate(
          { identity_role: 'companion', representative_name: ' 山田 ' },
          'representative',
        ),
      ).toEqual({ identityRole: 'companion', representativeName: '山田' });
    });
    it('name のみ + 現在 companion なら name を更新（空は null）', () => {
      expect(
        resolveRoleOnUpdate({ representative_name: ' 山田 ' }, 'companion'),
      ).toEqual({ representativeName: '山田' });
      expect(
        resolveRoleOnUpdate({ representative_name: '' }, 'companion'),
      ).toEqual({ representativeName: null });
    });
    it('name のみ + 現在 representative なら不変条件のため null に正規化', () => {
      expect(
        resolveRoleOnUpdate({ representative_name: '山田' }, 'representative'),
      ).toEqual({ representativeName: null });
    });
  });
});
