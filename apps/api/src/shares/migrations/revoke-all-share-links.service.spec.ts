import { Logger } from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import { REVOKE_ALL_SHARE_LINKS_SQL } from './revoke-all-share-links';
import { RevokeAllShareLinksService } from './revoke-all-share-links.service';

describe('RevokeAllShareLinksService', () => {
  beforeEach(() => {
    jest.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('AC-SI-60 移行 SQL をそのまま実行し、失効件数を返す', async () => {
    const executeRawUnsafe = jest.fn().mockResolvedValue(6);
    const service = new RevokeAllShareLinksService({
      $executeRawUnsafe: executeRawUnsafe,
    } as unknown as PrismaService);

    await expect(service.run()).resolves.toBe(6);
    expect(executeRawUnsafe).toHaveBeenCalledWith(REVOKE_ALL_SHARE_LINKS_SQL);
  });

  it('AC-SI-62 2 回目の実行は 0 件（既存の revoked_at を上書きしない）', async () => {
    const executeRawUnsafe = jest
      .fn()
      .mockResolvedValueOnce(6)
      .mockResolvedValueOnce(0);
    const service = new RevokeAllShareLinksService({
      $executeRawUnsafe: executeRawUnsafe,
    } as unknown as PrismaService);

    await service.run();
    await expect(service.run()).resolves.toBe(0);
  });
});
