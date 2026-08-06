import { MailSender } from './mail.sender';

/** DI トークンを実装するスタブ（テストで実際に使う形の一例）。 */
class StubMailSender extends MailSender {
  calls: Parameters<MailSender['send']>[0][] = [];
  shouldFail = false;

  send(input: { to: string; subject: string; text: string }): Promise<void> {
    this.calls.push(input);
    if (this.shouldFail) {
      return Promise.reject(new Error('mail provider unavailable'));
    }
    return Promise.resolve();
  }
}

describe('MailSender', () => {
  it('AC-T0-07 抽象クラスを DI トークンとしてスタブに差し替えられる（ネットワークに出ない）', async () => {
    const stub = new StubMailSender();
    const sender: MailSender = stub;

    await sender.send({ to: 'fan@example.com', subject: 's', text: 't' });

    expect(stub.calls).toEqual([
      { to: 'fan@example.com', subject: 's', text: 't' },
    ]);
  });

  it('send が例外を投げても、呼び出し元が catch すれば処理全体は壊れない（reset-request が常に 202 を返す設計の前提）', async () => {
    const stub = new StubMailSender();
    stub.shouldFail = true;
    const sender: MailSender = stub;

    // request-password-reset.use-case（T1）が採用する想定のパターン:
    // メール送信は fire-and-forget で例外を握りつぶし、呼び出し元の応答は変えない。
    let caught: unknown;
    const alwaysResolves = async () => {
      try {
        await sender.send({ to: 'fan@example.com', subject: 's', text: 't' });
      } catch (error) {
        caught = error;
      }
      return 'handled';
    };

    await expect(alwaysResolves()).resolves.toBe('handled');
    expect(caught).toBeInstanceOf(Error);
  });
});
