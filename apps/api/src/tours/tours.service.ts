import { Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { Prisma, Tour } from '@prisma/client';
import { AppError } from '../common/errors/app-error';
import { PrismaService } from '../prisma/prisma.service';
import { UpdateTourDto } from './dto/update-tour.dto';

/** api-contract.md §5 の tour レスポンス要素（snake_case）。 */
export interface TourResponse {
  id: string;
  name: string;
  artist_name_raw: string | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

/** POST /v1/applications の `tour` ブロック（find-or-create の入力）。 */
export interface TourFindOrCreateInput {
  id?: string;
  name: string;
  artist_name_raw?: string | null;
}

type TourClient = Pick<PrismaService, 'tour'>;

/**
 * ツアー (tours) のドメイン・認可 (ownerId)・Prisma アクセス (ADR-009)。
 * `POST /v1/tours` は提供せず、作成経路は applications の find-or-create のみ (D9)。
 */
@Injectable()
export class ToursService {
  constructor(private readonly prisma: PrismaService) {}

  async list(userId: string): Promise<TourResponse[]> {
    const rows = await this.prisma.tour.findMany({
      where: { ownerId: userId, deletedAt: null },
      orderBy: [{ name: 'asc' }],
    });
    return rows.map(toTourResponse);
  }

  async get(userId: string, id: string): Promise<TourResponse> {
    return toTourResponse(await this.assertOwned(userId, id));
  }

  async update(
    userId: string,
    id: string,
    dto: UpdateTourDto,
  ): Promise<TourResponse> {
    const current = await this.assertOwned(userId, id);

    const data: Prisma.TourUpdateInput = {};
    if (dto.name !== undefined) {
      if (dto.name !== current.name) {
        const conflict = await this.prisma.tour.findUnique({
          where: { ownerId_name: { ownerId: userId, name: dto.name } },
        });
        if (conflict) {
          throw AppError.conflict(`tour name already exists: ${dto.name}`);
        }
      }
      data.name = dto.name;
    }
    if (dto.artist_name_raw !== undefined) {
      data.artistNameRaw = dto.artist_name_raw;
    }

    const updated = await this.prisma.tour.update({ where: { id }, data });
    return toTourResponse(updated);
  }

  /**
   * ソフトデリート。冪等。
   * 配下 events / applications は**連鎖させない**（requirements C4 / AC-APP-21）。
   */
  async remove(userId: string, id: string): Promise<void> {
    const existing = await this.prisma.tour.findFirst({
      where: { id, ownerId: userId },
    });
    if (!existing) {
      throw AppError.notFound(`tour not found: ${id}`);
    }
    if (existing.deletedAt) return;

    await this.prisma.tour.update({
      where: { id },
      data: { deletedAt: new Date() },
    });
  }

  /** 他人 / 削除済み tour は NOT_FOUND 404 (BE-4)。 */
  async assertOwned(
    userId: string,
    id: string,
    tx?: Prisma.TransactionClient,
  ): Promise<Tour> {
    const client: TourClient = tx ?? this.prisma;
    const tour = await client.tour.findFirst({
      where: { id, ownerId: userId, deletedAt: null },
    });
    if (!tour) {
      throw AppError.notFound(`tour not found: ${id}`);
    }
    return tour;
  }

  /**
   * `(owner_id, name)` をキーにした find-or-create（api-contract.md §7 手順 1）。
   * ソフトデリート済みの同名 tour は `deleted_at = null` で復活させて再利用する
   * （`@@unique([ownerId, name])` は部分 unique にできないため — FR-AP-2）。
   */
  async findOrCreateByName(
    userId: string,
    input: TourFindOrCreateInput,
    tx?: Prisma.TransactionClient,
  ): Promise<Tour> {
    const client: TourClient = tx ?? this.prisma;

    const existing = await client.tour.findUnique({
      where: { ownerId_name: { ownerId: userId, name: input.name } },
    });

    if (existing) {
      if (existing.deletedAt === null) return existing;
      return client.tour.update({
        where: { id: existing.id },
        data: {
          deletedAt: null,
          artistNameRaw: input.artist_name_raw ?? existing.artistNameRaw,
        },
      });
    }

    return client.tour.create({
      data: {
        id: input.id ?? randomUUID(),
        ownerId: userId,
        name: input.name,
        artistNameRaw: input.artist_name_raw ?? null,
      },
    });
  }
}

export function toTourResponse(row: Tour): TourResponse {
  return {
    id: row.id,
    name: row.name,
    artist_name_raw: row.artistNameRaw,
    created_at: row.createdAt.toISOString(),
    updated_at: row.updatedAt.toISOString(),
    deleted_at: row.deletedAt ? row.deletedAt.toISOString() : null,
  };
}
