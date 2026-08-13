import { Injectable } from '@nestjs/common';
import { Prisma, ShareLink, ShareRecipient } from '@prisma/client';
import { PrismaService } from '../../prisma/prisma.service';

/**
 * `share_recipients` / id 起点の `share_links` 参照（share-account-invites）。
 *
 * `shares.service.ts`（T3 所有・shares/ 直下）を編集できない都合上、`ShareLink` の
 * id lookup もここに置く。Prisma アクセスは Service 層に閉じる（BE-3）。
 */
export type InboxRow = ShareRecipient & {
  shareLink: ShareLink & {
    owner: { profile: { accountId: string | null; displayName: string | null } | null };
  };
};

@Injectable()
export class ShareRecipientAccessService {
  constructor(private readonly prisma: PrismaService) {}

  /** id で ShareLink を取得する（token を経由しない）。 */
  async findLinkById(id: string): Promise<ShareLink | null> {
    return this.prisma.shareLink.findUnique({ where: { id } });
  }

  /** オーナーの account_id / display_name（プロフィール未作成なら null）。 */
  async findOwnerProfile(
    ownerId: string,
  ): Promise<{ accountId: string | null; displayName: string | null } | null> {
    const profile = await this.prisma.profile.findUnique({
      where: { id: ownerId },
      select: { accountId: true, displayName: true },
    });
    return profile ?? null;
  }

  /** `(shareLinkId, userId)` の招待行が存在するか（hidden でも存在扱い）。 */
  async findRecipient(
    shareLinkId: string,
    userId: string,
  ): Promise<ShareRecipient | null> {
    return this.prisma.shareRecipient.findFirst({
      where: { shareLinkId, userId },
    });
  }

  /**
   * 受信箱一覧（未失効・未期限切れ・非表示でない・オーナーが自分でない）。
   * 並びは `share_recipients.created_at desc`（api-contract-delta.md §4.1）。
   */
  async listInboxRows(userId: string, now: Date): Promise<InboxRow[]> {
    return this.prisma.shareRecipient.findMany({
      where: {
        userId,
        hiddenAt: null,
        shareLink: {
          revokedAt: null,
          ownerId: { not: userId },
          OR: [{ expiresAt: null }, { expiresAt: { gt: now } }],
        },
      },
      orderBy: { createdAt: 'desc' },
      include: {
        shareLink: {
          include: { owner: { include: { profile: true } } },
        },
      },
    }) as unknown as Promise<InboxRow[]>;
  }

  /**
   * tour 名のバッチ解決（scope_name 用）。tour id はグローバルに一意。
   * 論理削除済み（`deletedAt` 非null）のツアーは除外する。呼び出し元
   * （ListInboxUseCase）は解決できなかった tour スコープの行を一覧から除外する。
   */
  async resolveTourNames(tourIds: string[]): Promise<Map<string, string>> {
    const uniqueIds = [...new Set(tourIds)];
    if (uniqueIds.length === 0) return new Map();
    const tours = await this.prisma.tour.findMany({
      where: { id: { in: uniqueIds }, deletedAt: null },
      select: { id: true, name: true },
    });
    return new Map(tours.map((tour) => [tour.id, tour.name]));
  }

  /** 招待経由の閲覧でだけ呼ぶ（オーナー閲覧では呼ばない — api-contract-delta.md §4.2）。 */
  async markViewed(
    shareLinkId: string,
    userId: string,
    viewedAt: Date,
  ): Promise<void> {
    await this.prisma.shareRecipient.updateMany({
      where: { shareLinkId, userId },
      data: { lastViewedAt: viewedAt },
    });
  }

  /**
   * 非表示 / 表示の切り替え（冪等）。招待行が無ければ false を返す
   * （呼び出し元が SHARE_INVALID 404 に変換する）。
   */
  async setHidden(
    shareLinkId: string,
    userId: string,
    hidden: boolean,
  ): Promise<boolean> {
    const result: Prisma.BatchPayload = await this.prisma.shareRecipient.updateMany({
      where: { shareLinkId, userId },
      data: { hiddenAt: hidden ? new Date() : null },
    });
    return result.count > 0;
  }
}
