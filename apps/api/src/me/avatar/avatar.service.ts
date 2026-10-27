import { Injectable, Logger } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { PrismaService } from '../../prisma/prisma.service';
import { AvatarStorage } from './avatar.storage';

const P2021 = 'P2021'; // table does not exist
const P2003 = 'P2003'; // foreign key constraint failed

/**
 * `user_avatars` テーブルの読み書き（avatar-upload/api-contract-delta.md §0.2）。
 * Prisma エラーを契約コードへ写す（BE-6）。
 * - P2021（テーブル未作成）→ `findObjectKey` / `avatarUrl` は null + warn（1 プロセス 1 回で十分）
 *                           → `findObjectKeyOrUnavailable` / `replace` / `remove` は 503
 * - P2003（FK 違反）→ NOT_FOUND
 */
@Injectable()
export class AvatarService {
  private readonly logger = new Logger(AvatarService.name);
  private tableWarnedOnce = false;

  constructor(
    private readonly prisma: PrismaService,
    private readonly storage: AvatarStorage,
  ) {}

  /** P2021（テーブル無し）は null + warn ログ（寛容版）。 */
  async findObjectKey(userId: string): Promise<string | null> {
    try {
      const row = await this.prisma.userAvatar.findUnique({
        where: { userId },
        select: { objectKey: true },
      });
      return row?.objectKey ?? null;
    } catch (err) {
      if (isPrismaCode(err, P2021)) {
        if (!this.tableWarnedOnce) {
          this.tableWarnedOnce = true;
          this.logger.warn('user_avatars table does not exist — avatar_url will be null');
        }
        return null;
      }
      throw err;
    }
  }

  /** findObjectKey の厳格版。P2021 → SERVICE_UNAVAILABLE。 */
  async findObjectKeyOrUnavailable(userId: string): Promise<string | null> {
    try {
      const row = await this.prisma.userAvatar.findUnique({
        where: { userId },
        select: { objectKey: true },
      });
      return row?.objectKey ?? null;
    } catch (err) {
      if (isPrismaCode(err, P2021)) {
        throw new AppError(
          ErrorCode.SERVICE_UNAVAILABLE,
          'avatar is temporarily unavailable',
        );
      }
      throw err;
    }
  }

  /**
   * upsert して直前のキーを返す。
   * P2021 → SERVICE_UNAVAILABLE / P2003 → NOT_FOUND。
   */
  async replace(
    userId: string,
    objectKey: string,
  ): Promise<{ previousKey: string | null }> {
    try {
      // findUnique → upsert をトランザクションで行い、直前のキーを取得する
      const result = await this.prisma.$transaction(async (tx) => {
        const existing = await tx.userAvatar.findUnique({
          where: { userId },
          select: { objectKey: true },
        });
        await tx.userAvatar.upsert({
          where: { userId },
          create: { userId, objectKey },
          update: { objectKey },
        });
        return existing?.objectKey ?? null;
      });
      return { previousKey: result };
    } catch (err) {
      if (isPrismaCode(err, P2021)) {
        throw new AppError(
          ErrorCode.SERVICE_UNAVAILABLE,
          'avatar is temporarily unavailable',
        );
      }
      if (isPrismaCode(err, P2003)) {
        throw AppError.notFound('user not found');
      }
      throw err;
    }
  }

  /**
   * 行を消して直前のキーを返す（無ければ null）。
   * P2021 → SERVICE_UNAVAILABLE。
   */
  async remove(userId: string): Promise<{ previousKey: string | null }> {
    try {
      const existing = await this.prisma.userAvatar.findUnique({
        where: { userId },
        select: { objectKey: true },
      });
      if (existing) {
        await this.prisma.userAvatar.delete({ where: { userId } });
      }
      return { previousKey: existing?.objectKey ?? null };
    } catch (err) {
      if (isPrismaCode(err, P2021)) {
        throw new AppError(
          ErrorCode.SERVICE_UNAVAILABLE,
          'avatar is temporarily unavailable',
        );
      }
      throw err;
    }
  }

  /** GET /v1/me 用。findObjectKey + AvatarStorage.publicUrl。 */
  async avatarUrl(userId: string): Promise<string | null> {
    const key = await this.findObjectKey(userId);
    if (!key) return null;
    return this.storage.publicUrl(key);
  }
}

function isPrismaCode(err: unknown, code: string): boolean {
  return (
    err instanceof Prisma.PrismaClientKnownRequestError && err.code === code
  );
}
