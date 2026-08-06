import { Injectable } from '@nestjs/common';
import { Tour } from '@prisma/client';
import { fromDateOnly } from '../common/util/date.util';
import { PrismaService } from '../prisma/prisma.service';
import { ToursService } from './tours.service';

/** api-contract.md §5 `GET /v1/tours/:id/matrix` の 1 行。 */
export interface TourMatrixRow {
  event_id: string;
  event_name: string;
  venue_name: string | null;
  event_date: string | null;
  application_id: string;
  round_name: string | null;
  status: string;
  seat_raw: string | null;
  result_on: string | null;
  rep_identity_id: string;
  rep_name: string;
  rep_color: string;
  companion_names: string[];
}

/**
 * 共有ペイロード (T6) のマスキング判定に必要な内部情報を足した行。
 * `rep_history_visible = false` の行は共有時に rep_name / rep_color / seat をマスクする。
 */
export interface TourMatrixInternalRow extends TourMatrixRow {
  rep_history_visible: boolean;
}

export interface TourMatrixInternal {
  tour: Tour;
  rows: TourMatrixInternalRow[];
}

export interface TourMatrixResponse {
  tour_id: string;
  tour_name: string;
  rows: TourMatrixRow[];
}

/**
 * ツアー表 (event × application) の組み立て。DB ビューではなく Prisma クエリ (D8 / FR-AP-12)。
 * T6 (shares / public) はこの Service を再利用し、マスキングだけを追加する。
 */
@Injectable()
export class TourMatrixService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly tours: ToursService,
  ) {}

  /** 認証 API 用。契約どおりのレスポンス形（内部キーを含まない）。 */
  async buildMatrix(
    userId: string,
    tourId: string,
  ): Promise<TourMatrixResponse> {
    const { tour, rows } = await this.build(userId, tourId);
    return {
      tour_id: tour.id,
      tour_name: tour.name,
      rows: rows.map(stripInternal),
    };
  }

  /** T6 向け。マスキング判定用の rep_history_visible 付き。他人の tour は 404。 */
  async build(userId: string, tourId: string): Promise<TourMatrixInternal> {
    const tour = await this.tours.assertOwned(userId, tourId);

    const events = await this.prisma.event.findMany({
      where: { tourId: tour.id, ownerId: userId, deletedAt: null },
      orderBy: [{ eventDate: { sort: 'asc', nulls: 'last' } }, { name: 'asc' }],
      include: {
        applications: {
          where: { deletedAt: null },
          orderBy: [{ createdAt: 'asc' }, { id: 'asc' }],
          include: {
            repIdentity: true,
            companions: {
              where: { deletedAt: null },
              orderBy: { position: 'asc' },
              include: { identity: true },
            },
          },
        },
      },
    });

    const rows: TourMatrixInternalRow[] = [];
    for (const event of events) {
      for (const application of event.applications) {
        rows.push({
          event_id: event.id,
          event_name: event.name,
          venue_name: event.venueNameRaw,
          event_date: fromDateOnly(event.eventDate),
          application_id: application.id,
          round_name: application.roundName,
          status: application.status,
          seat_raw: application.seatRaw,
          result_on: fromDateOnly(application.resultOn),
          rep_identity_id: application.repIdentityId,
          rep_name: application.repIdentity.displayName,
          rep_color: application.repIdentity.color,
          // 同行者は identity_id があればその現在の display_name を使う (FR-AP-13)
          companion_names: application.companions.map(
            (companion) =>
              companion.identity?.displayName ?? companion.displayName,
          ),
          rep_history_visible: application.repIdentity.historyVisible,
        });
      }
    }

    return { tour, rows };
  }
}

function stripInternal(row: TourMatrixInternalRow): TourMatrixRow {
  const { rep_history_visible: _ignored, ...rest } = row;
  return rest;
}
