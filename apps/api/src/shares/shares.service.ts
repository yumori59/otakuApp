import { Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { ShareLink } from '@prisma/client';
import { AppError } from '../common/errors/app-error';
import { randomToken, sha256Hex } from '../common/util/hash.util';
import { PrismaService } from '../prisma/prisma.service';
import { ShareRecipientsService } from './share-recipients.service';
import { SharePermission, ShareScopeType } from './dto/create-share.dto';
import { ShareListItemResponse, toShareListItem } from './shares.presenter';

export interface CreateShareLinkInput {
  scopeType: ShareScopeType;
  scopeId: string | null;
  permission: SharePermission;
  maskMemberNo: boolean;
  expiresAt: Date | null;
}

/** 生トークンは呼び出し元（発行レスポンス）にだけ渡す。DB には hash しか無い。 */
export interface CreatedShareLink {
  row: ShareLink;
  token: string;
}

/** `POST /v1/shares` で招待する 1 件（実在確認済み・`share_recipients` の行データ）。 */
export interface CreateShareRecipientInput {
  accountId: string;
  userId: string;
}

/**
 * 共有リンク (share_links) のドメイン・認可 (ownerId)・Prisma アクセス (ADR-009)。
 * トークンは `sha256Hex` した値だけを保存し、平文検索もしない (FR-SH-1)。
 */
@Injectable()
export class SharesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly shareRecipients: ShareRecipientsService,
  ) {}

  /** 上限判定用。失効済み / 期限切れは数えない（AC-SH-03）。 */
  async countActive(userId: string, now: Date = new Date()): Promise<number> {
    return this.prisma.shareLink.count({
      where: {
        ownerId: userId,
        revokedAt: null,
        OR: [{ expiresAt: null }, { expiresAt: { gt: now } }],
      },
    });
  }

  /**
   * `share_links` + `share_recipients` を 1 トランザクションで作成する
   * （api-contract-delta.md §1 判定順序 ⑥）。招待は既に実在確認済みのものだけを渡すこと。
   */
  async createWithRecipients(
    userId: string,
    input: CreateShareLinkInput,
    recipients: CreateShareRecipientInput[],
  ): Promise<CreatedShareLink> {
    const token = randomToken();
    const id = randomUUID();
    const row = await this.prisma.$transaction(async (tx) => {
      const created = await tx.shareLink.create({
        data: {
          id,
          ownerId: userId,
          scopeType: input.scopeType,
          scopeId: input.scopeId,
          tokenHash: sha256Hex(token),
          permission: input.permission,
          maskMemberNo: input.maskMemberNo,
          expiresAt: input.expiresAt,
        },
      });
      if (recipients.length > 0) {
        await tx.shareRecipient.createMany({
          data: recipients.map((recipient) => ({
            id: randomUUID(),
            shareLinkId: id,
            accountId: recipient.accountId,
            userId: recipient.userId,
          })),
        });
      }
      return created;
    });
    return { row, token };
  }

  /** 自分の共有リンク一覧（失効済みも含む）。並びは created_at desc。 */
  async list(userId: string): Promise<ShareListItemResponse[]> {
    const rows = await this.prisma.shareLink.findMany({
      where: { ownerId: userId },
      orderBy: { createdAt: 'desc' },
    });

    const scopeNames = await this.tourNames(userId, rows);
    const recipientsByShareLink = await this.shareRecipients.listByShareLinks(
      rows.map((row) => row.id),
    );
    const now = new Date();
    return rows.map((row) =>
      toShareListItem(
        row,
        row.scopeId ? (scopeNames.get(row.scopeId) ?? null) : null,
        recipientsByShareLink.get(row.id) ?? [],
        now,
      ),
    );
  }

  /** 自分の共有リンクを 1 件取得する。他人 / 未知の id は NOT_FOUND 404 (BE-4)。 */
  async findOwned(userId: string, id: string): Promise<ShareLink> {
    const existing = await this.prisma.shareLink.findFirst({
      where: { id, ownerId: userId },
    });
    if (!existing) {
      throw AppError.notFound(`share not found: ${id}`);
    }
    return existing;
  }

  /** 失効。冪等（既に失効済みなら何もしない）。他人の id は NOT_FOUND 404 (BE-4)。 */
  async revoke(userId: string, id: string): Promise<void> {
    const existing = await this.findOwned(userId, id);
    if (existing.revokedAt) return;

    await this.prisma.shareLink.update({
      where: { id },
      data: { revokedAt: new Date() },
    });
  }

  /**
   * 生トークンを sha256 して照合する。**有効性は判定しない**
   * （失効 / 期限切れの扱いは ResolveShareUseCase が一括で SHARE_INVALID にする）。
   */
  async findByToken(token: string): Promise<ShareLink | null> {
    if (!token) return null;
    return this.prisma.shareLink.findUnique({
      where: { tokenHash: sha256Hex(token) },
    });
  }

  /** 有効な閲覧のときだけ呼ぶ（AC-SH-13 / AC-SH-14）。 */
  async recordView(id: string, viewedAt: Date = new Date()): Promise<void> {
    await this.prisma.shareLink.update({
      where: { id },
      data: { viewCount: { increment: 1 }, lastViewedAt: viewedAt },
    });
  }

  /**
   * 共有先による編集が**成功したときだけ**呼ぶ（AC-SW-20 / AC-SW-21）。
   * `view_count` は増やさない。
   */
  async recordEdit(id: string, editedAt: Date = new Date()): Promise<void> {
    await this.prisma.shareLink.update({
      where: { id },
      data: { editCount: { increment: 1 }, lastEditedAt: editedAt },
    });
  }

  /**
   * write 共有の公演数上限判定に使う、対象 tour の未削除 event 数（AC-SW-05 / AC-SW-05d）。
   * 申込ゼロの公演も 1 件と数える。ownerId スコープを外さない (BE-4)。
   */
  async countTourEvents(userId: string, tourId: string): Promise<number> {
    return this.prisma.event.count({
      where: { tourId, ownerId: userId, deletedAt: null },
    });
  }

  /** scope_name 用の tour 名解決。ownerId スコープを外さない (BE-4)。 */
  private async tourNames(
    userId: string,
    rows: ShareLink[],
  ): Promise<Map<string, string>> {
    const tourIds = [
      ...new Set(
        rows
          .filter((row) => row.scopeType === 'tour' && row.scopeId !== null)
          .map((row) => row.scopeId as string),
      ),
    ];
    if (tourIds.length === 0) return new Map();

    const tours = await this.prisma.tour.findMany({
      where: { id: { in: tourIds }, ownerId: userId },
      select: { id: true, name: true },
    });
    return new Map(tours.map((tour) => [tour.id, tour.name]));
  }
}
