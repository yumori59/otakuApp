import { buildPasswordResetMail } from './reset-mail';

describe('buildPasswordResetMail', () => {
  const mail = buildPasswordResetMail('04821093');

  it('AC-PR-05 件名は固定文言', () => {
    expect(mail.subject).toBe('【参戦名義帳】パスワード再設定のご案内');
  });

  it('AC-PR-05 本文にコードと有効期限（15 分）が含まれる', () => {
    expect(mail.text).toContain('04821093');
    expect(mail.text).toContain('15');
  });

  it('AC-PR-05 心当たりが無ければ無視してよい旨を書く', () => {
    expect(mail.text).toContain('心当たり');
  });

  it('AC-PR-05 他の個人情報（会員番号 / 名義 / メールアドレス）を載せない', () => {
    expect(mail.text).not.toMatch(/ACC-/);
    expect(mail.text).not.toMatch(/@/);
    expect(mail.text).not.toContain('名義');
  });
});
