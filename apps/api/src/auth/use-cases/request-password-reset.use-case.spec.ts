import { Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { sha256Hex } from '../../common/util/hash.util';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { MailSendInput, MailSender } from '../../mail/mail.sender';
import { PrismaService } from '../../prisma/prisma.service';
import { AccountIdGenerator } from '../account-id.generator';
import { AuthService } from '../auth.service';
import { RequestPasswordResetUseCase } from './request-password-reset.use-case';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const NOW = new Date('2026-08-01T00:00:00.000Z');
const TTL_MS = 15 * 60 * 1000;

const ENV: Record<string, string> = {
  JWT_ACCESS_SECRET: 'test-access-secret',
};

interface PrismaMock {
  user: { findUnique: jest.Mock };
  passwordResetCode: { create: jest.Mock; updateMany: jest.Mock };
  $transaction: jest.Mock;
}

describe('RequestPasswordResetUseCase', () => {
  let prisma: PrismaMock;
  let send: jest.Mock;
  let useCase: RequestPasswordResetUseCase;
  let loggerError: jest.SpyInstance;

  function userRow(overrides: Record<string, unknown> = {}) {
    return {
      id: USER_ID,
      email: 'Fan@Example.com',
      emailNormalized: 'fan@example.com',
      passwordHash: 'scrypt$N=1024,r=8,p=1$aaaa$bbbb',
      ...overrides,
    };
  }

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    loggerError = jest
      .spyOn(Logger.prototype, 'error')
      .mockImplementation(() => undefined);
    prisma = {
      user: { findUnique: jest.fn().mockResolvedValue(userRow()) },
      passwordResetCode: {
        create: jest.fn().mockResolvedValue(undefined),
        updateMany: jest.fn().mockResolvedValue({ count: 1 }),
      },
      $transaction: jest.fn(),
    };
    prisma.$transaction.mockImplementation((cb: (tx: PrismaMock) => unknown) =>
      Promise.resolve(cb(prisma)),
    );
    send = jest.fn().mockResolvedValue(undefined);

    const service = new AuthService(
      prisma as unknown as PrismaService,
      { signAsync: jest.fn() } as unknown as JwtService,
      { get: (key: string) => ENV[key] } as unknown as ConfigService,
      new AccountIdGenerator(),
      { get: jest.fn() } as unknown as EntitlementsService,
    );
    useCase = new RequestPasswordResetUseCase(service, {
      send,
    } as unknown as MailSender);
  });

  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  function sentMail(): MailSendInput {
    return send.mock.calls[0][0] as MailSendInput;
  }

  function createdCode(): Record<string, unknown> {
    return prisma.passwordResetCode.create.mock.calls[0][0].data as Record<
      string,
      unknown
    >;
  }

  it('AC-PR-01 登録済みユーザーでも戻り値は void（202 / 空ボディ）', async () => {
    await expect(
      useCase.execute({ email: 'fan@example.com' }),
    ).resolves.toBeUndefined();
    expect(send).toHaveBeenCalledTimes(1);
  });

  it('AC-PR-01/02 未登録 email はメールを送らず、同じく void を返す', async () => {
    prisma.user.findUnique.mockResolvedValue(null);

    await expect(
      useCase.execute({ email: 'nobody@example.com' }),
    ).resolves.toBeUndefined();

    expect(send).not.toHaveBeenCalled();
    expect(prisma.passwordResetCode.create).not.toHaveBeenCalled();
  });

  it('AC-PR-02 password_hash が null（Apple / Google のみ）にはメールを送らない', async () => {
    prisma.user.findUnique.mockResolvedValue(
      userRow({ passwordHash: null, appleSub: 'apple-sub' }),
    );

    await expect(
      useCase.execute({ email: 'fan@example.com' }),
    ).resolves.toBeUndefined();

    expect(send).not.toHaveBeenCalled();
    expect(prisma.passwordResetCode.create).not.toHaveBeenCalled();
  });

  it('AC-PR-01 検索は正規化 email で行う', async () => {
    await useCase.execute({ email: ' FAN@Example.com ' });

    expect(prisma.user.findUnique).toHaveBeenCalledWith({
      where: { emailNormalized: 'fan@example.com' },
    });
  });

  it('AC-PR-03 発行時に同一ユーザーの未使用コードをすべて失効させる（同一 TX）', async () => {
    await useCase.execute({ email: 'fan@example.com' });

    expect(prisma.$transaction).toHaveBeenCalledTimes(1);
    expect(prisma.passwordResetCode.updateMany).toHaveBeenCalledWith({
      where: { userId: USER_ID, usedAt: null },
      data: { usedAt: NOW },
    });
    expect(prisma.passwordResetCode.create).toHaveBeenCalledTimes(1);
  });

  it('AC-PR-04 DB には sha256(userId + ":" + code) のみが入り、平文コードは現れない', async () => {
    await useCase.execute({ email: 'fan@example.com' });

    const code = /\b(\d{8})\b/.exec(sentMail().text)?.[1];
    expect(code).toMatch(/^\d{8}$/);

    const data = createdCode();
    expect(data.codeHash).toBe(sha256Hex(`${USER_ID}:${code as string}`));
    expect(JSON.stringify(data)).not.toContain(code as string);
    expect(data.expiresAt).toEqual(new Date(NOW.getTime() + TTL_MS));
  });

  it('AC-PR-04 平文コードはログにも出さない', async () => {
    await useCase.execute({ email: 'fan@example.com' });

    const code = /\b(\d{8})\b/.exec(sentMail().text)?.[1] as string;
    const logged = JSON.stringify(loggerError.mock.calls);
    expect(logged).not.toContain(code);
  });

  it('AC-PR-05 送信先は users.email（元の表記）で、本文にコードと有効期限が載る', async () => {
    await useCase.execute({ email: 'fan@example.com' });

    expect(sentMail().to).toBe('Fan@Example.com');
    expect(sentMail().subject).toBe('【参戦名義帳】パスワード再設定のご案内');
    expect(sentMail().text).toMatch(/\d{8}/);
    expect(sentMail().text).toContain('15');
  });

  it('AC-PR-06 メール送信が例外を投げても呼び出しは成功のまま（202 を維持）', async () => {
    send.mockRejectedValue(new Error('resend is down'));

    await expect(
      useCase.execute({ email: 'fan@example.com' }),
    ).resolves.toBeUndefined();

    expect(loggerError).toHaveBeenCalled();
  });
});
