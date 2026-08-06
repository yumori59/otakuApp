import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';

export interface IdentityStatsItem {
  identity_id: string;
  application_count: number;
  won_count: number;
  lost_count: number;
  pending_count: number;
  win_rate_percent: number | null;
}

export interface IdentityStatsResponse {
  items: IdentityStatsItem[];
}

type Involvement = { identityId: string; status: string };

/**
 * 名義別統計 (`GET /v1/stats/identities`)。`v_identity_stats` 相当 (docs/03 §7.1)。
 */
@Injectable()
export class StatsService {
  constructor(private readonly prisma: PrismaService) {}

  async getIdentityStats(userId: string): Promise<IdentityStatsResponse> {
    const applications = await this.prisma.application.findMany({
      where: { ownerId: userId, deletedAt: null, status: { not: 'draft' } },
      select: {
        id: true,
        status: true,
        repIdentityId: true,
        companions: {
          where: { deletedAt: null, identityId: { not: null } },
          select: { identityId: true },
        },
      },
    });

    const byIdentity = new Map<string, Map<string, string>>();

    for (const app of applications) {
      addInvolvement(byIdentity, app.repIdentityId, app.id, app.status);
      for (const companion of app.companions) {
        if (companion.identityId) {
          addInvolvement(
            byIdentity,
            companion.identityId,
            app.id,
            app.status,
          );
        }
      }
    }

    const items: IdentityStatsItem[] = [...byIdentity.entries()]
      .map(([identityId, appsById]) => {
        const statuses = [...appsById.values()];
        const won = statuses.filter((s) => s === 'won').length;
        const lost = statuses.filter((s) => s === 'lost').length;
        const pending = statuses.filter((s) => s === 'applied').length;
        const decided = won + lost;
        return {
          identity_id: identityId,
          application_count: statuses.length,
          won_count: won,
          lost_count: lost,
          pending_count: pending,
          win_rate_percent:
            decided === 0
              ? null
              : Math.round((won / decided) * 1000) / 10,
        };
      })
      .sort((a, b) => a.identity_id.localeCompare(b.identity_id));

    return { items };
  }
}

function addInvolvement(
  byIdentity: Map<string, Map<string, string>>,
  identityId: string,
  applicationId: string,
  status: string,
): void {
  let apps = byIdentity.get(identityId);
  if (!apps) {
    apps = new Map();
    byIdentity.set(identityId, apps);
  }
  // union（重複排除）— 代表かつ同行の不整合データでも二重計上しない
  apps.set(applicationId, status);
}
