import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AppError } from '../common/errors/app-error';
import { ResendMailSender } from './resend.mail.sender';

const sendMock = jest.fn();

jest.mock('resend', () => ({
  Resend: jest.fn().mockImplementation(() => ({
    emails: { send: sendMock },
  })),
}));

// jest.requireMock は any を返すため、以降の no-unsafe-* 系ルールを避けるための明示アサーション
// eslint-disable-next-line @typescript-eslint/no-unnecessary-type-assertion
const { Resend } = jest.requireMock('resend') as { Resend: jest.Mock };

function configWith(values: Record<string, string | undefined>): ConfigService {
  return {
    get: (key: string) => values[key],
  } as unknown as ConfigService;
}

describe('ResendMailSender', () => {
  const ORIGINAL_NODE_ENV = process.env.NODE_ENV;

  beforeEach(() => {
    sendMock.mockReset();
    Resend.mockClear();
  });

  afterEach(() => {
    process.env.NODE_ENV = ORIGINAL_NODE_ENV;
  });

  it('AC-T0-06 本番で RESEND_API_KEY 未設定なら送信時に INTERNAL 500 を投げ、本文をログに出さない', async () => {
    process.env.NODE_ENV = 'production';
    const warnSpy = jest
      .spyOn(Logger.prototype, 'warn')
      .mockImplementation(() => undefined);
    const sender = new ResendMailSender(configWith({}));

    await expect(
      sender.send({
        to: 'fan@example.com',
        subject: 'subj',
        text: 'secret-code-12345678',
      }),
    ).rejects.toBeInstanceOf(AppError);
    await expect(
      sender.send({
        to: 'fan@example.com',
        subject: 'subj',
        text: 'secret-code-12345678',
      }),
    ).rejects.toMatchObject({ code: 'INTERNAL' });

    expect(Resend).not.toHaveBeenCalled();
    expect(warnSpy).not.toHaveBeenCalled();
    warnSpy.mockRestore();
  });

  it('中-1 NODE_ENV 未設定/staging など development/test 以外は fail closed（本文をログに出さず INTERNAL 500）', async () => {
    for (const env of [undefined, 'staging', 'typo-env']) {
      process.env.NODE_ENV = env;
      const warnSpy = jest
        .spyOn(Logger.prototype, 'warn')
        .mockImplementation(() => undefined);
      const sender = new ResendMailSender(configWith({}));

      await expect(
        sender.send({
          to: 'fan@example.com',
          subject: 'subj',
          text: 'secret-code-12345678',
        }),
      ).rejects.toMatchObject({ code: 'INTERNAL' });

      expect(Resend).not.toHaveBeenCalled();
      expect(warnSpy).not.toHaveBeenCalled();
      warnSpy.mockRestore();
    }
  });

  it('AC-T0-07 非本番で RESEND_API_KEY 未設定なら送信せず、ネットワークに出ない（フォールバックログのみ）', async () => {
    process.env.NODE_ENV = 'development';
    const warnSpy = jest
      .spyOn(Logger.prototype, 'warn')
      .mockImplementation(() => undefined);
    const sender = new ResendMailSender(configWith({}));

    await expect(
      sender.send({ to: 'fan@example.com', subject: 'subj', text: '12345678' }),
    ).resolves.toBeUndefined();

    expect(Resend).not.toHaveBeenCalled();
    expect(sendMock).not.toHaveBeenCalled();
    expect(warnSpy).toHaveBeenCalled();
    warnSpy.mockRestore();
  });

  it('AC-T0-07 RESEND_API_KEY が設定済みなら Resend.emails.send を呼ぶ', async () => {
    process.env.NODE_ENV = 'development';
    sendMock.mockResolvedValue({ data: { id: 'email_1' }, error: null });
    const sender = new ResendMailSender(
      configWith({
        RESEND_API_KEY: 're_test_key',
        RESEND_FROM_EMAIL: 'no-reply@example.com',
      }),
    );

    await expect(
      sender.send({ to: 'fan@example.com', subject: 'subj', text: 'body' }),
    ).resolves.toBeUndefined();

    expect(Resend).toHaveBeenCalledWith('re_test_key');
    expect(sendMock).toHaveBeenCalledWith({
      from: 'no-reply@example.com',
      to: 'fan@example.com',
      subject: 'subj',
      text: 'body',
    });
  });

  it('Resend が error を返したら AppError(INTERNAL) を投げる', async () => {
    sendMock.mockResolvedValue({
      data: null,
      error: { name: 'application_error', message: 'boom' },
    });
    const sender = new ResendMailSender(
      configWith({ RESEND_API_KEY: 're_test_key' }),
    );

    await expect(
      sender.send({ to: 'fan@example.com', subject: 'subj', text: 'body' }),
    ).rejects.toMatchObject({ code: 'INTERNAL' });
  });
});
