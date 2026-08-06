import { Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { Application, Membership, Prisma } from '@prisma/client';
import { AppError } from '../common/errors/app-error';
import { toDateOnly } from '../common/util/date.util';
import { PrismaService } from '../prisma/prisma.service';
import {
  ApplicationResponse,
  ApplicationRowLike,
  toApplicationResponse,
} from './applications.presenter';
import { DEFAULT_APPLICATION_STATUS } from './dto/application-status';
import {
  ApplicationCompanionDto,
  CreateApplicationDto,
} from './dto/create-application.dto';
import { ListApplicationsQueryDto } from './dto/list-applications-query.dto';
import { UpdateApplicationDto } from './dto/update-application.dto';

export interface ApplicationListResponse {
  items: ApplicationResponse[];
  next_cursor: string | null;
  has_more: boolean;
}

type ApplicationClient = Pick<
  PrismaService,
  'application' | 'applicationCompanion' | 'membership'
>;

/** companions は position asc の未削除のみ（api-contract.md §7）。 */
const APPLICATION_INCLUDE = {
  event: { select: { tourId: true } },
  companions: {
    where: { deletedAt: null },
    orderBy: { position: 'asc' as const },
  },
};

/**
 * 申込 (applications) のドメイン・認可 (ownerId)・Prisma アクセス (ADR-009)。
 * 横断フロー（tour find-or-create → event upsert → 検証 → 作成）は use-cases 側。
 */
@Injectable()
export class ApplicationsService {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * use-case が Prisma を直接触らずに TX を張るための入口 (BE-3)。
   */
  transaction<T>(
    fn: (tx: Prisma.TransactionClient) => Promise<T>,
  ): Promise<T> {
    return this.prisma.$transaction(fn);
  }

  async list(
    userId: string,
    query: ListApplicationsQueryDto,
  ): Promise<ApplicationListResponse> {
    const where: Prisma.ApplicationWhereInput = { ownerId: userId };
    if (!query.include_deleted) where.deletedAt = null;
    if (query.status?.length) where.status = { in: query.status };
    if (query.event_id) where.eventId = query.event_id;
    if (query.tour_id) where.event = { tourId: query.tour_id };
    if (query.rep_identity_id) where.repIdentityId = query.rep_identity_id;
    if (query.cursor) {
      // orderBy が (updated_at, id) なので、カーソルも複合で比較しないと
      // updated_at 同値の行が limit 境界でまるごと飛ぶ
      const cursor = parseCursor(query.cursor);
      where.OR = [
        { updatedAt: { gt: cursor.updatedAt } },
        { updatedAt: cursor.updatedAt, id: { gt: cursor.id } },
      ];
    }

    const limit = query.limit;
    const rows = (await this.prisma.application.findMany({
      where,
      include: APPLICATION_INCLUDE,
      orderBy: [{ updatedAt: 'asc' }, { id: 'asc' }],
      take: limit + 1,
    })) as unknown as ApplicationRowLike[];

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;
    const last = page[page.length - 1];

    return {
      items: page.map(toApplicationResponse),
      next_cursor: last ? formatCursor(last.updatedAt, last.id) : null,
      has_more: hasMore,
    };
  }

  async get(userId: string, id: string): Promise<ApplicationResponse> {
    const row = (await this.prisma.application.findFirst({
      where: { id, ownerId: userId, deletedAt: null },
      include: APPLICATION_INCLUDE,
    })) as ApplicationRowLike | null;
    if (!row) {
      throw AppError.notFound(`application not found: ${id}`);
    }
    return toApplicationResponse(row);
  }

  /** application と配下 companions をソフトデリート。冪等。 */
  async remove(userId: string, id: string): Promise<void> {
    const existing = await this.prisma.application.findFirst({
      where: { id, ownerId: userId },
    });
    if (!existing) {
      throw AppError.notFound(`application not found: ${id}`);
    }
    if (existing.deletedAt) return;

    const deletedAt = new Date();
    await this.transaction(async (tx) => {
      await tx.application.update({ where: { id }, data: { deletedAt } });
      await tx.applicationCompanion.updateMany({
        where: { applicationId: id, deletedAt: null },
        data: { deletedAt },
      });
    });
  }

  /** 他人 / 削除済み application は NOT_FOUND 404 (BE-4)。 */
  async assertOwned(
    userId: string,
    id: string,
    tx?: Prisma.TransactionClient,
  ): Promise<Application> {
    const client: ApplicationClient = tx ?? this.prisma;
    const row = await client.application.findFirst({
      where: { id, ownerId: userId, deletedAt: null },
    });
    if (!row) {
      throw AppError.notFound(`application not found: ${id}`);
    }
    return row;
  }

  /** 既存 id への再 POST を検出するための素引き（削除済みも含む）。 */
  async findRawById(
    id: string,
    tx?: Prisma.TransactionClient,
  ): Promise<Application | null> {
    const client: ApplicationClient = tx ?? this.prisma;
    return client.application.findUnique({ where: { id } });
  }

  /**
   * rep_membership_id の検証（api-contract.md §7 手順 4 / FR-AP-4）。
   * 自分の未削除 membership かつ `identity_id === repIdentityId` でなければ 404。
   */
  async assertMembershipOwned(
    userId: string,
    membershipId: string,
    identityId: string,
    tx?: Prisma.TransactionClient,
  ): Promise<Membership> {
    const membership = await this.findMembershipOwned(
      userId,
      membershipId,
      identityId,
      tx,
    );
    if (!membership) {
      throw AppError.notFound(`membership not found: ${membershipId}`);
    }
    return membership;
  }

  /**
   * `assertMembershipOwned` の非例外版。
   * 既存の `rep_membership_id` が新しい代表名義にまだ属しているかの
   * 再検証（自動クリア判定）に使う。
   */
  async findMembershipOwned(
    userId: string,
    membershipId: string,
    identityId: string,
    tx?: Prisma.TransactionClient,
  ): Promise<Membership | null> {
    const client: ApplicationClient = tx ?? this.prisma;
    return client.membership.findFirst({
      where: {
        id: membershipId,
        ownerId: userId,
        identityId,
        deletedAt: null,
      },
    });
  }

  /** application + companions の作成（api-contract.md §7 手順 6）。 */
  async create(
    userId: string,
    dto: CreateApplicationDto,
    eventId: string,
    tx: Prisma.TransactionClient,
  ): Promise<ApplicationResponse> {
    const id = dto.id ?? randomUUID();

    await tx.application.create({
      data: {
        id,
        ownerId: userId,
        eventId,
        repIdentityId: dto.rep_identity_id,
        repMembershipId: dto.rep_membership_id ?? null,
        roundName: dto.round_name ?? null,
        appliedOn: dto.applied_on ? toDateOnly(dto.applied_on) : null,
        resultOn: dto.result_on ? toDateOnly(dto.result_on) : null,
        status: dto.status ?? DEFAULT_APPLICATION_STATUS,
        seatRaw: dto.seat_raw ?? null,
        ticketCount: dto.ticket_count ?? 1,
        priceYen: dto.price_yen ?? null,
        note: dto.note ?? null,
      },
    });

    const companions = normalizeCompanions(dto.companions ?? []);
    if (companions.length > 0) {
      await tx.applicationCompanion.createMany({
        data: companions.map((companion) => ({
          id: companion.id,
          ownerId: userId,
          applicationId: id,
          identityId: companion.identityId,
          displayName: companion.displayName,
          position: companion.position,
        })),
      });
    }

    return this.findResponseOrThrow(id, tx);
  }

  /**
   * application のスカラー更新 + companions の全置換（FR-AP-8）。
   * `dto.companions` が undefined なら companions は一切触らない (AC-APP-12)。
   */
  async applyUpdate(
    userId: string,
    id: string,
    dto: UpdateApplicationDto,
    tx: Prisma.TransactionClient,
  ): Promise<ApplicationResponse> {
    const data: Prisma.ApplicationUncheckedUpdateInput = {};
    if (dto.rep_identity_id !== undefined) {
      data.repIdentityId = dto.rep_identity_id;
    }
    if (dto.rep_membership_id !== undefined) {
      data.repMembershipId = dto.rep_membership_id;
    }
    if (dto.round_name !== undefined) data.roundName = dto.round_name;
    if (dto.applied_on !== undefined) {
      data.appliedOn = dto.applied_on === null ? null : toDateOnly(dto.applied_on);
    }
    if (dto.result_on !== undefined) {
      data.resultOn = dto.result_on === null ? null : toDateOnly(dto.result_on);
    }
    if (dto.status !== undefined) data.status = dto.status;
    if (dto.seat_raw !== undefined) data.seatRaw = dto.seat_raw;
    if (dto.ticket_count !== undefined) data.ticketCount = dto.ticket_count;
    if (dto.price_yen !== undefined) data.priceYen = dto.price_yen;
    if (dto.note !== undefined) data.note = dto.note;

    await tx.application.update({ where: { id }, data });

    if (dto.companions !== undefined) {
      await this.replaceCompanions(userId, id, dto.companions, tx);
    }

    return this.findResponseOrThrow(id, tx);
  }

  private async replaceCompanions(
    userId: string,
    applicationId: string,
    incomingDto: ApplicationCompanionDto[],
    tx: Prisma.TransactionClient,
  ): Promise<void> {
    // 削除済みも読む。同じ id が再送されたら create（主キー重複 → P2002）ではなく
    // 復活させる（tours.findOrCreateByName と同じパターン / BE-6）
    const existing = await tx.applicationCompanion.findMany({
      where: { applicationId },
    });
    const incoming = normalizeCompanions(incomingDto);
    const incomingIds = new Set(incoming.map((companion) => companion.id));
    const existingIds = new Set(existing.map((companion) => companion.id));

    const removedIds = existing
      .filter(
        (companion) =>
          companion.deletedAt === null && !incomingIds.has(companion.id),
      )
      .map((companion) => companion.id);
    if (removedIds.length > 0) {
      await tx.applicationCompanion.updateMany({
        where: { id: { in: removedIds } },
        data: { deletedAt: new Date() },
      });
    }

    for (const companion of incoming) {
      if (existingIds.has(companion.id)) {
        await tx.applicationCompanion.update({
          where: { id: companion.id },
          data: {
            identityId: companion.identityId,
            displayName: companion.displayName,
            position: companion.position,
            deletedAt: null,
          },
        });
      } else {
        await tx.applicationCompanion.create({
          data: {
            id: companion.id,
            ownerId: userId,
            applicationId,
            identityId: companion.identityId,
            displayName: companion.displayName,
            position: companion.position,
          },
        });
      }
    }
  }

  private async findResponseOrThrow(
    id: string,
    tx: Prisma.TransactionClient,
  ): Promise<ApplicationResponse> {
    const row = (await tx.application.findUnique({
      where: { id },
      include: APPLICATION_INCLUDE,
    })) as ApplicationRowLike | null;
    if (!row) {
      throw AppError.notFound(`application not found: ${id}`);
    }
    return toApplicationResponse(row);
  }
}

const CURSOR_SEPARATOR = '|';
// バージョンは検証しない（BE-1）。カーソルの id 部分が UUID の形をしていることだけ確認する。
const UUID_SHAPE_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** `<updated_at ISO>|<id>` の opaque カーソル (api-contract.md §0)。 */
function formatCursor(updatedAt: Date, id: string): string {
  return `${updatedAt.toISOString()}${CURSOR_SEPARATOR}${id}`;
}

/** 壊れたカーソルは黙って先頭に落とさず 400 にする (BE-2)。 */
function parseCursor(raw: string): { updatedAt: Date; id: string } {
  const separator = raw.indexOf(CURSOR_SEPARATOR);
  const updatedAt = separator > 0 ? new Date(raw.slice(0, separator)) : null;
  const id = separator > 0 ? raw.slice(separator + 1) : '';
  if (
    !updatedAt ||
    Number.isNaN(updatedAt.getTime()) ||
    !UUID_SHAPE_REGEX.test(id)
  ) {
    throw AppError.validation(
      'invalid cursor: pass back next_cursor as-is without modifying it',
    );
  }
  return { updatedAt, id };
}

interface NormalizedCompanion {
  id: string;
  identityId: string | null;
  displayName: string;
  position: number;
}

function normalizeCompanions(
  companions: ApplicationCompanionDto[],
): NormalizedCompanion[] {
  return companions.map((companion, index) => ({
    id: companion.id ?? randomUUID(),
    identityId: companion.identity_id ?? null,
    displayName: companion.display_name,
    position: companion.position ?? index,
  }));
}
