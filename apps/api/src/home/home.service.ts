import { Injectable } from '@nestjs/common';
import { fromDateOnly } from '../common/util/date.util';
import {
  daysUntilRenewal,
  renewalUrgency,
  todayJstDateString,
} from '../common/util/renewal.util';
import { PrismaService } from '../prisma/prisma.service';

export interface UpcomingRenewalItem {
  membership_id: string;
  identity_name: string;
  identity_color: string;
  fan_club_name: string;
  renewal_on: string;
  days_until: number;
  urgency: ReturnType<typeof renewalUrgency>;
}

export interface PendingApplicationItem {
  application_id: string;
  event_name: string;
  result_on: string | null;
  rep_name: string;
  status: string;
}

export interface HomeSummaryResponse {
  identity_count: number;
  renewals_within_30_days: number;
  pending_results: number;
  upcoming_renewals: UpcomingRenewalItem[];
  pending_applications: PendingApplicationItem[];
}

/**
 * ホーム集約 (`GET /v1/home/summary`)。DB ビューではなく Prisma クエリ (C2)。
 */
@Injectable()
export class HomeService {
  constructor(private readonly prisma: PrismaService) {}

  async getSummary(userId: string): Promise<HomeSummaryResponse> {
    const todayYmd = todayJstDateString();

    const [identityCount, memberships, pendingApps] = await Promise.all([
      this.prisma.identity.count({
        where: { ownerId: userId, deletedAt: null },
      }),
      this.prisma.membership.findMany({
        where: {
          ownerId: userId,
          deletedAt: null,
          renewalOn: { not: null },
          identity: { deletedAt: null },
        },
        include: { identity: true },
        orderBy: [{ renewalOn: 'asc' }, { createdAt: 'asc' }],
      }),
      this.prisma.application.findMany({
        where: { ownerId: userId, deletedAt: null, status: 'applied' },
        include: {
          event: true,
          repIdentity: true,
        },
        orderBy: [
          { resultOn: { sort: 'asc', nulls: 'last' } },
          { createdAt: 'asc' },
        ],
      }),
    ]);

    const upcomingRenewals: UpcomingRenewalItem[] = [];
    let renewalsWithin30Days = 0;

    for (const membership of memberships) {
      const renewalOn = fromDateOnly(membership.renewalOn)!;
      const daysUntil = daysUntilRenewal(membership.renewalOn!, todayYmd);
      if (daysUntil >= 0 && daysUntil <= 30) {
        renewalsWithin30Days += 1;
      }
      upcomingRenewals.push({
        membership_id: membership.id,
        identity_name: membership.identity.displayName,
        identity_color: membership.identity.color,
        fan_club_name: membership.fanClubNameRaw,
        renewal_on: renewalOn,
        days_until: daysUntil,
        urgency: renewalUrgency(daysUntil),
      });
    }

    const pendingApplications: PendingApplicationItem[] = pendingApps.map(
      (app) => ({
        application_id: app.id,
        event_name: app.event.name,
        result_on: fromDateOnly(app.resultOn),
        rep_name: app.repIdentity.displayName,
        status: app.status,
      }),
    );

    return {
      identity_count: identityCount,
      renewals_within_30_days: renewalsWithin30Days,
      pending_results: pendingApplications.length,
      upcoming_renewals: upcomingRenewals,
      pending_applications: pendingApplications,
    };
  }
}
