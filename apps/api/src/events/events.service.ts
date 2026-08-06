import { Injectable } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { Event, Prisma } from '@prisma/client';
import { AppError } from '../common/errors/app-error';
import { fromDateOnly, toDateOnly } from '../common/util/date.util';
import { PrismaService } from '../prisma/prisma.service';
import { UpdateEventDto } from './dto/update-event.dto';

/** api-contract.md §6 の event レスポンス要素（snake_case）。 */
export interface EventResponse {
  id: string;
  tour_id: string;
  name: string;
  venue_name_raw: string | null;
  event_date: string | null;
  starts_at: string | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

/** POST /v1/applications の `event` ブロック（upsert の入力）。 */
export interface EventUpsertInput {
  id?: string;
  name: string;
  venue_name_raw?: string | null;
  event_date?: string | null;
  starts_at?: string | null;
}

type EventClient = Pick<PrismaService, 'event'>;

/**
 * 公演 (events) のドメイン・認可 (ownerId)・Prisma アクセス (ADR-009)。
 * `POST /v1/events` は提供せず、作成経路は applications の find-or-create のみ (D9)。
 */
@Injectable()
export class EventsService {
  constructor(private readonly prisma: PrismaService) {}

  async list(userId: string, tourId?: string): Promise<EventResponse[]> {
    const where: Prisma.EventWhereInput = { ownerId: userId, deletedAt: null };
    if (tourId !== undefined) where.tourId = tourId;

    const rows = await this.prisma.event.findMany({
      where,
      orderBy: [{ eventDate: { sort: 'asc', nulls: 'last' } }, { name: 'asc' }],
    });
    return rows.map(toEventResponse);
  }

  async get(userId: string, id: string): Promise<EventResponse> {
    return toEventResponse(await this.assertOwned(userId, id));
  }

  async update(
    userId: string,
    id: string,
    dto: UpdateEventDto,
  ): Promise<EventResponse> {
    await this.assertOwned(userId, id);

    const data: Prisma.EventUpdateInput = {};
    if (dto.name !== undefined) data.name = dto.name;
    if (dto.venue_name_raw !== undefined) data.venueNameRaw = dto.venue_name_raw;
    if (dto.event_date !== undefined) {
      data.eventDate = dto.event_date === null ? null : toDateOnly(dto.event_date);
    }
    if (dto.starts_at !== undefined) {
      data.startsAt = dto.starts_at === null ? null : new Date(dto.starts_at);
    }

    const updated = await this.prisma.event.update({ where: { id }, data });
    return toEventResponse(updated);
  }

  /** ソフトデリート。冪等。配下 applications は連鎖させない（C4）。 */
  async remove(userId: string, id: string): Promise<void> {
    const existing = await this.prisma.event.findFirst({
      where: { id, ownerId: userId },
    });
    if (!existing) {
      throw AppError.notFound(`event not found: ${id}`);
    }
    if (existing.deletedAt) return;

    await this.prisma.event.update({
      where: { id },
      data: { deletedAt: new Date() },
    });
  }

  /** 他人 / 削除済み event は NOT_FOUND 404 (BE-4)。 */
  async assertOwned(
    userId: string,
    id: string,
    tx?: Prisma.TransactionClient,
  ): Promise<Event> {
    const client: EventClient = tx ?? this.prisma;
    const event = await client.event.findFirst({
      where: { id, ownerId: userId, deletedAt: null },
    });
    if (!event) {
      throw AppError.notFound(`event not found: ${id}`);
    }
    return event;
  }

  /**
   * api-contract.md §7 手順 2 の upsert。`ownerId` / `tourId` はサーバーが設定する。
   * 既存 event が他人のものなら NOT_FOUND 404（TX ロールバック）。
   */
  async upsertForApplication(
    userId: string,
    tourId: string,
    input: EventUpsertInput,
    tx?: Prisma.TransactionClient,
  ): Promise<Event> {
    const client: EventClient = tx ?? this.prisma;
    const id = input.id ?? randomUUID();

    const existing = await client.event.findUnique({ where: { id } });
    if (existing && existing.ownerId !== userId) {
      throw AppError.notFound(`event not found: ${id}`);
    }

    if (existing) {
      // tourId はリレーション FK なので Unchecked 版で更新する（サーバー設定）
      const data: Prisma.EventUncheckedUpdateInput = {
        tourId,
        name: input.name,
        deletedAt: null,
      };
      if (input.venue_name_raw !== undefined) {
        data.venueNameRaw = input.venue_name_raw;
      }
      if (input.event_date !== undefined) {
        data.eventDate =
          input.event_date === null ? null : toDateOnly(input.event_date);
      }
      if (input.starts_at !== undefined) {
        data.startsAt = input.starts_at === null ? null : new Date(input.starts_at);
      }
      return client.event.update({ where: { id }, data });
    }

    return client.event.create({
      data: {
        id,
        ownerId: userId,
        tourId,
        name: input.name,
        venueNameRaw: input.venue_name_raw ?? null,
        eventDate: input.event_date ? toDateOnly(input.event_date) : null,
        startsAt: input.starts_at ? new Date(input.starts_at) : null,
      },
    });
  }
}

export function toEventResponse(row: Event): EventResponse {
  return {
    id: row.id,
    tour_id: row.tourId,
    name: row.name,
    venue_name_raw: row.venueNameRaw,
    event_date: fromDateOnly(row.eventDate),
    starts_at: row.startsAt ? row.startsAt.toISOString() : null,
    created_at: row.createdAt.toISOString(),
    updated_at: row.updatedAt.toISOString(),
    deleted_at: row.deletedAt ? row.deletedAt.toISOString() : null,
  };
}
