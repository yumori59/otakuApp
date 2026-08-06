import { ConfigService } from '@nestjs/config';
import { JwtService } from '@nestjs/jwt';
import { EntitlementsService } from '../entitlements/entitlements.service';
import { PrismaService } from '../prisma/prisma.service';
import { sha256Hex } from '../common/util/hash.util';
import { AccountIdGenerator } from './account-id.generator';
import { AuthService } from './auth.service';

const USER_ID = '018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f';
const NOW = new Date('2026-08-01T00:00:00.000Z');
const DAY_MS = 24 * 60 * 60 * 1000;

const ENV: Record<string, string> = {
  JWT_ACCESS_SECRET: 'test-access-secret',
  JWT_ACCESS_TTL_SECONDS: '3600',
  REFRESH_TTL_DAYS: '30',
};

interface PrismaMock {
  user: { findUnique: jest.Mock };
  refreshToken: {
    findUnique: jest.Mock;
    create: jest.Mock;
    updateMany: jest.Mock;
  };
  $transaction: jest.Mock;
}

function createPrismaMock(): PrismaMock {
  const prisma: PrismaMock = {
    user: { findUnique: jest.fn() },
    refreshToken: {
      findUnique: jest.fn(),
      create: jest.fn().mockResolvedValue(undefined),
      updateMany: jest.fn().mockResolvedValue({ count: 1 }),
    },
    $transaction: jest.fn(),
  };
  // $transaction(cb) はコールバックを同期的に tx モックで実行する
  prisma.$transaction.mockImplementation((cb: (tx: PrismaMock) => unknown) =>
    Promise.resolve(cb(prisma)),
  );
  return prisma;
}

describe('AuthService', () => {
  let prisma: PrismaMock;
  let jwt: { signAsync: jest.Mock };
  let config: { get: jest.Mock };
  let env: Record<string, string | undefined>;
  let service: AuthService;

  beforeEach(() => {
    jest.useFakeTimers().setSystemTime(NOW);
    env = { ...ENV };
    prisma = createPrismaMock();
    jwt = { signAsync: jest.fn().mockResolvedValue('signed.access.token') };
    config = { get: jest.fn((key: string) => env[key]) };
    service = new AuthService(
      prisma as unknown as PrismaService,
      jwt as unknown as JwtService,
      config as unknown as ConfigService,
      new AccountIdGenerator(),
      { get: jest.fn() } as unknown as EntitlementsService,
    );
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  describe('issueRefreshToken', () => {
    it('AC-AUTH-05 refresh token は平文で保存されず sha256 hex のみが DB に入る', async () => {
      const issued = await service.issueRefreshToken(USER_ID);

      expect(issued.token).toEqual(expect.any(String));
      expect(issued.token.length).toBeGreaterThan(20);

      expect(prisma.refreshToken.create).toHaveBeenCalledTimes(1);
      const data = prisma.refreshToken.create.mock.calls[0][0].data as Record<
        string,
        unknown
      >;
      expect(data.tokenHash).toBe(sha256Hex(issued.token));
      expect(data.tokenHash).not.toBe(issued.token);
      expect(data.userId).toBe(USER_ID);
      expect(JSON.stringify(data)).not.toContain(issued.token);
    });

    it('AC-AUTH-05 生成のたびに異なるトークンになる', async () => {
      const first = await service.issueRefreshToken(USER_ID);
      const second = await service.issueRefreshToken(USER_ID);

      expect(first.token).not.toBe(second.token);
      expect(first.id).not.toBe(second.id);
    });

    it('expires_at は REFRESH_TTL_DAYS 日後になる', async () => {
      env.REFRESH_TTL_DAYS = '7';

      const issued = await service.issueRefreshToken(USER_ID);

      expect(issued.expiresAt).toEqual(new Date(NOW.getTime() + 7 * DAY_MS));
      const data = prisma.refreshToken.create.mock.calls[0][0].data as {
        expiresAt: Date;
      };
      expect(data.expiresAt).toEqual(new Date(NOW.getTime() + 7 * DAY_MS));
    });

    it('REFRESH_TTL_DAYS 未設定なら既定 30 日', async () => {
      env.REFRESH_TTL_DAYS = undefined;

      const issued = await service.issueRefreshToken(USER_ID);

      expect(issued.expiresAt).toEqual(new Date(NOW.getTime() + 30 * DAY_MS));
    });
  });

  describe('issueAccessToken', () => {
    it('sub にユーザー ID を載せ JWT_ACCESS_SECRET で署名する', async () => {
      const issued = await service.issueAccessToken(USER_ID);

      expect(issued).toEqual({
        accessToken: 'signed.access.token',
        expiresIn: 3600,
      });
      expect(jwt.signAsync).toHaveBeenCalledWith(
        { sub: USER_ID },
        { secret: 'test-access-secret', expiresIn: 3600 },
      );
    });

    it('JWT_ACCESS_TTL_SECONDS 未設定なら既定 3600 秒', async () => {
      env.JWT_ACCESS_TTL_SECONDS = undefined;

      await expect(service.issueAccessToken(USER_ID)).resolves.toMatchObject({
        expiresIn: 3600,
      });
    });

    it('JWT_ACCESS_SECRET 未設定なら INTERNAL 500（無署名で発行しない）', async () => {
      env.JWT_ACCESS_SECRET = undefined;

      await expect(service.issueAccessToken(USER_ID)).rejects.toMatchObject({
        code: 'INTERNAL',
      });
      expect(jwt.signAsync).not.toHaveBeenCalled();
    });
  });

  describe('findRefreshToken', () => {
    it('AC-AUTH-05 生トークンではなくハッシュで検索する', async () => {
      prisma.refreshToken.findUnique.mockResolvedValue(null);

      await service.findRefreshToken('raw-token');

      expect(prisma.refreshToken.findUnique).toHaveBeenCalledWith({
        where: { tokenHash: sha256Hex('raw-token') },
      });
    });
  });

  describe('rotateRefreshToken', () => {
    const row = {
      id: '018f3c2a-2222-7c90-9d2a-000000000001',
      userId: USER_ID,
      tokenHash: sha256Hex('old-token'),
      expiresAt: new Date(NOW.getTime() + DAY_MS),
      revokedAt: null,
      replacedBy: null,
      createdAt: NOW,
    };

    it('AC-AUTH-06 旧トークンを失効させ、新しい行を同一 TX で作る', async () => {
      const rotated = await service.rotateRefreshToken(row);

      expect(rotated).not.toBeNull();
      expect(prisma.$transaction).toHaveBeenCalledTimes(1);

      expect(prisma.refreshToken.updateMany).toHaveBeenCalledWith({
        where: { id: row.id, revokedAt: null },
        data: { revokedAt: NOW, replacedBy: rotated?.id },
      });
      const data = prisma.refreshToken.create.mock.calls[0][0].data as Record<
        string,
        unknown
      >;
      expect(data.id).toBe(rotated?.id);
      expect(data.userId).toBe(USER_ID);
      expect(data.tokenHash).toBe(sha256Hex(rotated?.token as string));
    });

    it('AC-AUTH-07 既に失効していた（更新 0 件）なら null を返し新しい行を作らない (E-13)', async () => {
      prisma.refreshToken.updateMany.mockResolvedValue({ count: 0 });

      await expect(service.rotateRefreshToken(row)).resolves.toBeNull();
      expect(prisma.refreshToken.create).not.toHaveBeenCalled();
    });
  });

  describe('revokeRefreshTokenByRaw', () => {
    it('AC-AUTH-08 ハッシュ一致かつ未失効の行のみ revoked_at を立てる', async () => {
      await service.revokeRefreshTokenByRaw('raw-token');

      expect(prisma.refreshToken.updateMany).toHaveBeenCalledWith({
        where: { tokenHash: sha256Hex('raw-token'), revokedAt: null },
        data: { revokedAt: NOW },
      });
    });

    it('AC-AUTH-08 該当が無くても例外を投げない（冪等）', async () => {
      prisma.refreshToken.updateMany.mockResolvedValue({ count: 0 });

      await expect(
        service.revokeRefreshTokenByRaw('unknown-token'),
      ).resolves.toBeUndefined();
    });
  });
});
