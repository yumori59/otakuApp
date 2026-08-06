import { Injectable } from '@nestjs/common';
import { Identity, Prisma } from '@prisma/client';
import { AppError } from '../common/errors/app-error';
import { ErrorCode } from '../common/errors/error-codes';
import { fromDateOnly, toDateOnly } from '../common/util/date.util';
import { EntitlementsService } from '../entitlements/entitlements.service';
import { PrismaService } from '../prisma/prisma.service';
import { CreateIdentityDto } from './dto/create-identity.dto';
import { UpdateIdentityDto } from './dto/update-identity.dto';

/** api-contract.md §3 の identity レスポンス要素（snake_case）。 */
export interface IdentityResponse {
  id: string;
  display_name: string;
  relation: string;
  color: string;
  joined_on: string | null;
  note: string | null;
  history_visible: boolean;
  sort_order: number;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

type PrismaClientLike = Pick<PrismaService, 'identity'>;

/**
 * 名義 (identities) のドメイン・認可 (ownerId)・Prisma アクセス (ADR-009)。
 * `assertOwned` は memberships / tours / events / applications (T4/T5) が
 * 親 identity の所有検証に再利用する公開契約。
 */
@Injectable()
export class IdentitiesService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly entitlements: EntitlementsService,
  ) {}

  async list(userId: string, includeDeleted: boolean): Promise<IdentityResponse[]> {
    const rows = await this.prisma.identity.findMany({
      where: includeDeleted
        ? { ownerId: userId }
        : { ownerId: userId, deletedAt: null },
      orderBy: [{ sortOrder: 'asc' }, { createdAt: 'asc' }],
    });
    return rows.map(toIdentityResponse);
  }

  async get(userId: string, id: string): Promise<IdentityResponse> {
    const identity = await this.assertOwned(userId, id);
    return toIdentityResponse(identity);
  }

  async create(userId: string, dto: CreateIdentityDto): Promise<IdentityResponse> {
    const existing = await this.prisma.identity.findUnique({
      where: { id: dto.id },
    });
    if (existing) {
      throw AppError.conflict(`identity already exists: ${dto.id}`);
    }

    const limit = await this.entitlements.identityLimit(userId);
    if (limit !== null) {
      const current = await this.prisma.identity.count({
        where: { ownerId: userId, deletedAt: null },
      });
      if (current >= limit) {
        throw new AppError(
          ErrorCode.PLAN_LIMIT_IDENTITY,
          `identity limit reached (limit=${limit}, current=${current})`,
          { limit, current },
        );
      }
    }

    const created = await this.prisma.identity.create({
      data: {
        id: dto.id,
        ownerId: userId,
        displayName: dto.display_name,
        relation: dto.relation ?? 'other',
        color: dto.color ?? '#0017C1',
        joinedOn: dto.joined_on ? toDateOnly(dto.joined_on) : null,
        note: dto.note ?? null,
        historyVisible: dto.history_visible ?? false,
        sortOrder: dto.sort_order ?? 0,
      },
    });
    return toIdentityResponse(created);
  }

  async update(
    userId: string,
    id: string,
    dto: UpdateIdentityDto,
  ): Promise<IdentityResponse> {
    await this.assertOwned(userId, id);

    const data: Prisma.IdentityUpdateInput = {};
    if (dto.display_name !== undefined) data.displayName = dto.display_name;
    if (dto.relation !== undefined) data.relation = dto.relation;
    if (dto.color !== undefined) data.color = dto.color;
    if (dto.joined_on !== undefined) {
      data.joinedOn = dto.joined_on === null ? null : toDateOnly(dto.joined_on);
    }
    if (dto.note !== undefined) data.note = dto.note;
    if (dto.history_visible !== undefined) data.historyVisible = dto.history_visible;
    if (dto.sort_order !== undefined) data.sortOrder = dto.sort_order;

    const updated = await this.prisma.identity.update({ where: { id }, data });
    return toIdentityResponse(updated);
  }

  /** ソフトデリート。冪等（既に削除済みでも成功）。他人 / 存在しない id は 404。 */
  async remove(userId: string, id: string): Promise<void> {
    const existing = await this.prisma.identity.findFirst({
      where: { id, ownerId: userId },
    });
    if (!existing) {
      throw AppError.notFound(`identity not found: ${id}`);
    }
    if (existing.deletedAt) return;

    await this.prisma.identity.update({
      where: { id },
      data: { deletedAt: new Date() },
    });
  }

  /**
   * Sync push 等で新規 identity を upsert する前に名義上限を検証する。
   * 既存（未削除）行の更新は枠を消費しない。
   */
  async ensureWithinLimit(
    userId: string,
    identityId: string,
    tx?: Prisma.TransactionClient,
  ): Promise<void> {
    const client: PrismaClientLike = tx ?? this.prisma;
    const existing = await client.identity.findFirst({
      where: { id: identityId, ownerId: userId, deletedAt: null },
    });
    if (existing) return;

    const limit = await this.entitlements.identityLimit(userId);
    if (limit === null) return;

    const current = await client.identity.count({
      where: { ownerId: userId, deletedAt: null },
    });
    if (current >= limit) {
      throw new AppError(
        ErrorCode.PLAN_LIMIT_IDENTITY,
        `identity limit reached (limit=${limit}, current=${current})`,
        { limit, current },
      );
    }
  }

  /**
   * 他モジュール (memberships / tours / events / applications) が
   * 親 identity の所有・未削除を検証するための公開メソッド。
   * 他人 / 削除済み id は NOT_FOUND 404。
   */
  async assertOwned(
    userId: string,
    identityId: string,
    tx?: Prisma.TransactionClient,
  ): Promise<Identity> {
    const client: PrismaClientLike = tx ?? this.prisma;
    const identity = await client.identity.findFirst({
      where: { id: identityId, ownerId: userId, deletedAt: null },
    });
    if (!identity) {
      throw AppError.notFound(`identity not found: ${identityId}`);
    }
    return identity;
  }
}

function toIdentityResponse(row: Identity): IdentityResponse {
  return {
    id: row.id,
    display_name: row.displayName,
    relation: row.relation,
    color: row.color,
    joined_on: fromDateOnly(row.joinedOn),
    note: row.note,
    history_visible: row.historyVisible,
    sort_order: row.sortOrder,
    created_at: row.createdAt.toISOString(),
    updated_at: row.updatedAt.toISOString(),
    deleted_at: row.deletedAt ? row.deletedAt.toISOString() : null,
  };
}
