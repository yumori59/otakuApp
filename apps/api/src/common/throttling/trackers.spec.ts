import {
  emailTracker,
  tokenTracker,
  userShareTracker,
  userTracker,
} from './trackers';

describe('throttling trackers', () => {
  describe('emailTracker', () => {
    it('AC-T0-05 body.email を trim().toLowerCase() して返す', () => {
      expect(emailTracker({ body: { email: '  Fan@Example.com ' } })).toBe(
        'fan@example.com',
      );
    });

    it('AC-T0-05 email が無ければ空文字', () => {
      expect(emailTracker({ body: {} })).toBe('');
      expect(emailTracker({})).toBe('');
    });
  });

  describe('userTracker', () => {
    it('AC-T0-05 req.user.id を返す', () => {
      expect(userTracker({ user: { id: 'user-1' } })).toBe('user-1');
    });

    it('AC-T0-05 user が無ければ空文字', () => {
      expect(userTracker({})).toBe('');
    });
  });

  describe('tokenTracker', () => {
    it('AC-T0-05 req.params.token を返す', () => {
      expect(tokenTracker({ params: { token: 'tok-1' } })).toBe('tok-1');
    });

    it('AC-T0-05 params が無ければ空文字', () => {
      expect(tokenTracker({})).toBe('');
    });
  });

  describe('userShareTracker', () => {
    it('AC-SI-05 req.user.id と req.params.id を `:` で連結して返す', () => {
      expect(
        userShareTracker({ user: { id: 'user-1' }, params: { id: 'share-1' } }),
      ).toBe('user-1:share-1');
    });

    it('AC-SI-05 user / params が無ければ空文字部分を連結する', () => {
      expect(userShareTracker({})).toBe(':');
    });
  });
});
