import { Injectable } from '@nestjs/common';
import { IdentitiesService } from '../identities/identities.service';
import { PrismaService } from '../prisma/prisma.service';

/**
 * identity_summary 共有の集計行（**内部表現**）。
 * ここには identity_id を持たせない — 公開ペイロードへ漏れる経路を作らないため。
 */
export interface IdentitySummaryRow {
  displayName: string;
  historyVisible: boolean;
  applicationCount: number;
  wonCount: number;
}

/** 当選扱いにする application.status（api-contract.md §0 enum）。 */
const WON_STATUS = 'won';

/**
 * identity_summary 共有の集計 (D10)。
 * 名義一覧は IdentitiesService（ownerId スコープ済み）を再利用し、
 * 申込件数だけをこの Service で数える（Service 層なので Prisma 可 — ADR-009）。
 */
@Injectable()
export class IdentitySummaryService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly identities: IdentitiesService,
  ) {}

  /** 共有リンクのオーナーの未削除名義について申込件数 / 当選件数を数える。 */
  async build(ownerId: string): Promise<IdentitySummaryRow[]> {
    const identities = await this.identities.list(ownerId, false);
    if (identities.length === 0) return [];

    const identityIds = identities.map((identity) => identity.id);
    const grouped = await this.prisma.application.groupBy({
      by: ['repIdentityId', 'status'],
      where: {
        ownerId,
        deletedAt: null,
        repIdentityId: { in: identityIds },
      },
      _count: { _all: true },
    });

    const total = new Map<string, number>();
    const won = new Map<string, number>();
    for (const group of grouped) {
      const count = group._count._all;
      total.set(
        group.repIdentityId,
        (total.get(group.repIdentityId) ?? 0) + count,
      );
      if (group.status === WON_STATUS) {
        won.set(
          group.repIdentityId,
          (won.get(group.repIdentityId) ?? 0) + count,
        );
      }
    }

    return identities.map((identity) => ({
      displayName: identity.display_name,
      historyVisible: identity.history_visible,
      applicationCount: total.get(identity.id) ?? 0,
      wonCount: won.get(identity.id) ?? 0,
    }));
  }
}
