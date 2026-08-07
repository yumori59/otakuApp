import { Injectable } from '@nestjs/common';
import { ShareRecipient } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { PrismaService } from '../prisma/prisma.service';
import { ShareRecipientResponse } from './shares.presenter';

/** ACC-ID の実在確認で解決できた 1 件（`resolveAccountIds` の戻り値要素）。 */
export interface ResolvedAccount {
  accountId: string;
  userId: string;
  displayName: string | null;
}

export interface ResolveAccountIdsResult {
  resolved: ResolvedAccount[];
  /** 実在しなかった ACC-ID（入力順）。`SHARE_RECIPIENT_UNKNOWN.details.unknown_account_ids` に使う。 */
  unknown: string[];
}

/**
 * `share_recipients`（招待 ACL）のドメイン・Prisma アクセス (ADR-009)。
 * `profiles.account_id` の実在確認・招待の作成/追加/削除・一覧の display_name 解決を担う。
 */
@Injectable()
export class ShareRecipientsService {
  constructor(private readonly prisma: PrismaService) {}

  /** 呼び出し元自身の account_id（self 判定用）。プロフィール未作成なら null。 */
  async resolveOwnAccountId(userId: string): Promise<string | null> {
    const profile = await this.prisma.profile.findUnique({
      where: { id: userId },
      select: { accountId: true },
    });
    return profile?.accountId ?? null;
  }

  /**
   * ACC-XXXXXX の実在確認を一括で行う（`profiles.account_id` を 1 回の findMany で引く）。
   * 入力の順序を保った `resolved` / `unknown` を返す。呼び出し元で重複排除しておくこと。
   */
  async resolveAccountIds(
    accountIds: string[],
  ): Promise<ResolveAccountIdsResult> {
    if (accountIds.length === 0) return { resolved: [], unknown: [] };

    const profiles = await this.prisma.profile.findMany({
      where: { accountId: { in: accountIds } },
      select: { id: true, accountId: true, displayName: true },
    });
    const byAccountId = new Map(
      profiles
        .filter((profile) => profile.accountId !== null)
        .map((profile) => [profile.accountId as string, profile]),
    );

    const resolved: ResolvedAccount[] = [];
    const unknown: string[] = [];
    for (const accountId of accountIds) {
      const profile = byAccountId.get(accountId);
      if (!profile) {
        unknown.push(accountId);
        continue;
      }
      resolved.push({
        accountId,
        userId: profile.id,
        displayName: profile.displayName,
      });
    }
    return { resolved, unknown };
  }

  /** shareLinkId に紐づく現在の招待件数（20 件上限判定用）。 */
  async countByShareLink(shareLinkId: string): Promise<number> {
    return this.prisma.shareRecipient.count({ where: { shareLinkId } });
  }

  /** shareLinkId に紐づく既存招待の account_id 一覧（冪等判定・上限計算用）。 */
  async accountIdsByShareLink(shareLinkId: string): Promise<Set<string>> {
    const rows = await this.prisma.shareRecipient.findMany({
      where: { shareLinkId },
      select: { accountId: true },
    });
    return new Set(rows.map((row) => row.accountId));
  }

  /**
   * 招待行を追加する（既存 ACC-ID は `skipDuplicates` で無視し `invited_at` を更新しない — AC-SI-08）。
   * `@@unique([shareLinkId, accountId])` に依存する。
   */
  async addMany(
    shareLinkId: string,
    entries: { accountId: string; userId: string }[],
  ): Promise<void> {
    if (entries.length === 0) return;
    await this.prisma.shareRecipient.createMany({
      data: entries.map((entry) => ({
        id: randomUUID(),
        shareLinkId,
        accountId: entry.accountId,
        userId: entry.userId,
      })),
      skipDuplicates: true,
    });
  }

  /** 招待を削除する。存在しなくても成功する（冪等 — AC-SI-09）。 */
  async remove(shareLinkId: string, accountId: string): Promise<void> {
    await this.prisma.shareRecipient.deleteMany({
      where: { shareLinkId, accountId },
    });
  }

  /** 1 リンク分の招待一覧を invited_at 昇順・display_name 解決込みで返す。 */
  async listByShareLink(shareLinkId: string): Promise<ShareRecipientResponse[]> {
    const rows = await this.prisma.shareRecipient.findMany({
      where: { shareLinkId },
      orderBy: { createdAt: 'asc' },
    });
    return this.toResponses(rows);
  }

  /** 複数リンク分をまとめて解決する（`GET /v1/shares` の一覧用。N+1 回避）。 */
  async listByShareLinks(
    shareLinkIds: string[],
  ): Promise<Map<string, ShareRecipientResponse[]>> {
    const byId = new Map<string, ShareRecipientResponse[]>();
    if (shareLinkIds.length === 0) return byId;

    const rows = await this.prisma.shareRecipient.findMany({
      where: { shareLinkId: { in: shareLinkIds } },
      orderBy: { createdAt: 'asc' },
    });
    // rows と responses は toResponses が 1:1 変換するので同じ index を持つ。
    const responses = await this.toResponses(rows);
    rows.forEach((row, index) => {
      const list = byId.get(row.shareLinkId) ?? [];
      list.push(responses[index]);
      byId.set(row.shareLinkId, list);
    });
    return byId;
  }

  /** display_name を一括解決して `ShareRecipientResponse[]` に変換する（rows と同じ並びを保つ）。 */
  private async toResponses(
    rows: ShareRecipient[],
  ): Promise<ShareRecipientResponse[]> {
    const userIds = [...new Set(rows.map((row) => row.userId))];
    const profiles = userIds.length
      ? await this.prisma.profile.findMany({
          where: { id: { in: userIds } },
          select: { id: true, displayName: true },
        })
      : [];
    const nameByUserId = new Map(
      profiles.map((profile) => [profile.id, profile.displayName]),
    );

    return rows.map((row) => ({
      account_id: row.accountId,
      display_name: nameByUserId.get(row.userId) ?? null,
      invited_at: row.createdAt.toISOString(),
      last_viewed_at: row.lastViewedAt ? row.lastViewedAt.toISOString() : null,
    }));
  }
}
