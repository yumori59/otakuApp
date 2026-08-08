import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../../prisma/prisma.service';
import { REVOKE_ALL_SHARE_LINKS_SQL } from './revoke-all-share-links';

/**
 * 移行 SQL の実行担当（Prisma に触れるのは Service まで — ADR-009 / BE-3）。
 * SQL は定数で外部入力を含まないため `$executeRawUnsafe` を使う。
 */
@Injectable()
export class RevokeAllShareLinksService {
  private readonly logger = new Logger(RevokeAllShareLinksService.name);

  constructor(private readonly prisma: PrismaService) {}

  /** 失効させた行数を返す。2 回目以降は 0（冪等 — AC-SI-62）。 */
  async run(): Promise<number> {
    const revoked = await this.prisma.$executeRawUnsafe(
      REVOKE_ALL_SHARE_LINKS_SQL,
    );
    this.logger.log(`revoked ${revoked} share link(s)`);
    return revoked;
  }
}
