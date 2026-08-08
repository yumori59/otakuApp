import { Injectable } from '@nestjs/common';
import { Application } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';

/** 共有先に開放するのは status / seat だけ（api-contract-delta.md §4）。 */
export interface SharedItemPatch {
  status?: string;
  seatRaw?: string | null;
}

/**
 * 共有リンク（write）経由の application 読み書き。Prisma アクセスは Service 層に閉じる (BE-3 / ADR-009)。
 *
 * **すべてのクエリを共有リンクのオーナー (`ownerId`) でスコープする** (BE-4)。
 * 呼び出し元（use-case）は token を解決した結果の `link.ownerId` しか渡さない。
 *
 * `ApplicationsService` ではなくここに置いてある理由:
 * 楽観ロック（`updated_at` 一致時だけ更新する条件付き更新）は共有 write 専用の
 * プリミティブで、`applications` モジュールは本タスクのスコープ外のため。
 */
@Injectable()
export class SharedApplicationsService {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * rev 計算用の `updated_at`（application_id → updated_at）。
   * matrix と同じ条件（未削除 application / 未削除 event / 自分の tour）で引く。
   */
  async findUpdatedAtByTour(
    ownerId: string,
    tourId: string,
  ): Promise<Map<string, Date>> {
    const rows = await this.prisma.application.findMany({
      where: {
        ownerId,
        deletedAt: null,
        event: { tourId, ownerId, deletedAt: null },
      },
      select: { id: true, updatedAt: true },
    });
    return new Map(rows.map((row) => [row.id, row.updatedAt]));
  }

  /** 409 の `details.current` を組み立てるための読み直し。 */
  async findOwned(ownerId: string, id: string): Promise<Application | null> {
    return this.prisma.application.findFirst({
      where: { id, ownerId, deletedAt: null },
    });
  }

  /**
   * 楽観ロック更新。`updated_at` が期待値と一致する行だけを更新し、更新後の行を返す。
   * 一致する行が無ければ **何も書かずに** null（呼び出し元が CONFLICT / SHARE_INVALID に写す）。
   */
  async updateIfUnchanged(
    ownerId: string,
    id: string,
    expectedUpdatedAt: Date,
    patch: SharedItemPatch,
  ): Promise<Application | null> {
    return this.prisma.$transaction(async (tx) => {
      const result = await tx.application.updateMany({
        where: { id, ownerId, deletedAt: null, updatedAt: expectedUpdatedAt },
        data: patch,
      });
      if (result.count === 0) return null;
      return tx.application.findUnique({ where: { id } });
    });
  }
}
