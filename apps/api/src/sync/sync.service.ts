import { Injectable } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { AppError } from '../common/errors/app-error';
import { IdentitiesService } from '../identities/identities.service';
import { PrismaService } from '../prisma/prisma.service';
import { SyncPushDto } from './dto/sync.dto';
import {
  isSyncCollection,
  SYNC_COLLECTIONS,
  SYNC_PULL_LIMIT,
  SyncCollection,
} from './sync-collections';
import {
  isDeletedPayload,
  payloadToPrismaData,
} from './sync-payload.mapper';
import { serializeSyncRecord } from './sync-serialize';

export interface SyncPullResponse {
  changes: Record<string, unknown[]>;
  next_cursor: string | null;
  has_more: boolean;
}

export interface SyncPushRejectedItem {
  id: string;
  code: string;
  message: string;
}

export interface SyncPushResponse {
  accepted: string[];
  rejected: SyncPushRejectedItem[];
  server_time: string;
}

type SyncClient = PrismaService | Prisma.TransactionClient;

/**
 * LWW 差分同期 (docs/04-api.md §4)。identities〜application_companions。
 */
@Injectable()
export class SyncService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly identities: IdentitiesService,
  ) {}

  async pull(
    userId: string,
    cursor: string | null | undefined,
    collections: string[],
  ): Promise<SyncPullResponse> {
    const since = cursor ? new Date(cursor) : new Date(0);
    const changes: Record<string, unknown[]> = {};
    let maxUpdatedAt = since.getTime();
    let hasMore = false;

    for (const collection of collections) {
      if (!isSyncCollection(collection)) continue;
      const rows = await this.findChangesSince(
        this.prisma,
        collection,
        userId,
        since,
      );

      if (rows.length >= SYNC_PULL_LIMIT) hasMore = true;
      changes[collection] = rows.map((row) =>
        serializeSyncRecord(collection, row),
      );

      for (const row of rows) {
        const updatedAt = (row.updatedAt as Date).getTime();
        if (updatedAt > maxUpdatedAt) maxUpdatedAt = updatedAt;
      }
    }

    for (const collection of SYNC_COLLECTIONS) {
      if (!(collection in changes)) changes[collection] = [];
    }

    const nextCursor =
      maxUpdatedAt > since.getTime()
        ? new Date(maxUpdatedAt).toISOString()
        : cursor ?? null;

    return {
      changes,
      next_cursor: nextCursor,
      has_more: hasMore,
    };
  }

  async push(userId: string, dto: SyncPushDto): Promise<SyncPushResponse> {
    const accepted: string[] = [];
    const rejected: SyncPushRejectedItem[] = [];

    await this.prisma.$transaction(async (tx) => {
      for (const mutation of dto.mutations) {
        if (!isSyncCollection(mutation.collection) || mutation.op !== 'upsert') {
          rejected.push({
            id: mutation.id,
            code: 'SYNC_APPLY_FAILED',
            message: 'unsupported mutation',
          });
          continue;
        }

        const collection = mutation.collection;

        try {
          const existing = await this.findOwnedById(
            tx,
            collection,
            mutation.id,
          );

          if (existing && existing.ownerId !== userId) {
            rejected.push({
              id: mutation.id,
              code: 'SYNC_APPLY_FAILED',
              message: 'record not owned by user',
            });
            continue;
          }

          if (
            existing &&
            existing.updatedAt.getTime() > new Date(mutation.updated_at).getTime()
          ) {
            rejected.push({
              id: mutation.id,
              code: 'SYNC_LWW_REJECT',
              message: 'server copy is newer',
            });
            continue;
          }

          if (
            collection === 'identities' &&
            !isDeletedPayload(mutation.payload)
          ) {
            await this.identities.ensureWithinLimit(
              userId,
              mutation.id,
              tx,
            );
          }

          const data = payloadToPrismaData(collection, mutation.payload);

          const fkError = await this.validateForeignKeys(
            tx,
            collection,
            userId,
            data,
          );
          if (fkError) {
            rejected.push({
              id: mutation.id,
              code: 'SYNC_APPLY_FAILED',
              message: fkError,
            });
            continue;
          }

          const uniqueError = await this.validateUniqueConstraints(
            tx,
            collection,
            userId,
            mutation.id,
            data,
          );
          if (uniqueError) {
            rejected.push({
              id: mutation.id,
              code: 'SYNC_APPLY_FAILED',
              message: uniqueError,
            });
            continue;
          }

          await this.upsertRecord(tx, collection, mutation.id, userId, data);

          accepted.push(mutation.id);
        } catch (error) {
          if (error instanceof AppError) {
            rejected.push(rejectFromAppError(mutation.id, error));
            continue;
          }
          // Prisma／DB由来の想定外エラーはここで rejected に積まない。
          // Postgres はトランザクション内で1クエリでもエラーになるとabort状態になり、
          // 以後 COMMIT しても暗黙 ROLLBACK される（=このバッチの他の accepted も消える）。
          // ここで握り潰すと「accepted」が嘘になる（2026-08-18 実測）。
          // rethrow して $transaction 自体を失敗させ、push() 全体をエラー応答にする。
          // outbox 側は何もmarkSyncedされないため、次サイクルで安全に再送される。
          throw error;
        }
      }
    });

    return {
      accepted,
      rejected,
      server_time: new Date().toISOString(),
    };
  }

  private async findChangesSince(
    client: SyncClient,
    collection: SyncCollection,
    userId: string,
    since: Date,
  ): Promise<Record<string, unknown>[]> {
    const where = { ownerId: userId, updatedAt: { gt: since } };
    const orderBy = { updatedAt: 'asc' as const };
    const take = SYNC_PULL_LIMIT;

    switch (collection) {
      case 'identities':
        return client.identity.findMany({ where, orderBy, take });
      case 'memberships':
        return client.membership.findMany({ where, orderBy, take });
      case 'tours':
        return client.tour.findMany({ where, orderBy, take });
      case 'events':
        return client.event.findMany({ where, orderBy, take });
      case 'applications':
        return client.application.findMany({ where, orderBy, take });
      case 'application_companions':
        return client.applicationCompanion.findMany({ where, orderBy, take });
    }
  }

  private async findOwnedById(
    client: SyncClient,
    collection: SyncCollection,
    id: string,
  ): Promise<{ ownerId: string; updatedAt: Date } | null> {
    switch (collection) {
      case 'identities':
        return client.identity.findUnique({ where: { id } });
      case 'memberships':
        return client.membership.findUnique({ where: { id } });
      case 'tours':
        return client.tour.findUnique({ where: { id } });
      case 'events':
        return client.event.findUnique({ where: { id } });
      case 'applications':
        return client.application.findUnique({ where: { id } });
      case 'application_companions':
        return client.applicationCompanion.findUnique({ where: { id } });
    }
  }

  /**
   * payload 内の外部キーが呼び出し元 (userId) の所有物かを検証する。
   * FK が null/undefined ならスキップ (application_companions.identityId のテキスト直接入力を許容)。
   * deletedAt は条件に含めない — 削除済み親を参照する tombstone を正当に通すため。
   */
  private async validateForeignKeys(
    client: SyncClient,
    collection: SyncCollection,
    userId: string,
    data: Record<string, unknown>,
  ): Promise<string | null> {
    type FkCheck = {
      field: string;
      label: string;
      find: (id: string) => Promise<{ ownerId: string } | null>;
    };

    let checks: FkCheck[];
    switch (collection) {
      case 'memberships':
        checks = [
          {
            field: 'identityId',
            label: 'referenced identity',
            find: (id) => client.identity.findUnique({ where: { id } }),
          },
        ];
        break;
      case 'events':
        checks = [
          {
            field: 'tourId',
            label: 'referenced tour',
            find: (id) => client.tour.findUnique({ where: { id } }),
          },
        ];
        break;
      case 'applications':
        checks = [
          {
            field: 'eventId',
            label: 'referenced event',
            find: (id) => client.event.findUnique({ where: { id } }),
          },
          {
            field: 'repIdentityId',
            label: 'referenced identity',
            find: (id) => client.identity.findUnique({ where: { id } }),
          },
          {
            field: 'repMembershipId',
            label: 'referenced membership',
            find: (id) => client.membership.findUnique({ where: { id } }),
          },
        ];
        break;
      case 'application_companions':
        checks = [
          {
            field: 'applicationId',
            label: 'referenced application',
            find: (id) => client.application.findUnique({ where: { id } }),
          },
          {
            field: 'identityId',
            label: 'referenced identity',
            find: (id) => client.identity.findUnique({ where: { id } }),
          },
        ];
        break;
      case 'identities':
      case 'tours':
        checks = [];
        break;
    }

    for (const check of checks) {
      const value = data[check.field];
      if (value === null || value === undefined) continue;
      if (typeof value !== 'string') continue;

      const row = await check.find(value);
      if (!row || row.ownerId !== userId) {
        return `${check.label} not owned by user`;
      }
    }

    return null;
  }

  /**
   * upsert が Postgres の unique 制約違反を起こす前に事前検出する。
   * Postgres のインタラクティブトランザクションは 1 クエリでもエラーになると
   * トランザクション全体が abort し、以後の全クエリ (同一バッチの他の正当な
   * mutation を含む) が巻き添えで失敗する。SAVEPOINT でのリカバリではなく、
   * そもそも例外を発生させない方針を取る。
   *
   * 対象は tours の (owner_id, name) 一意制約 (schema.prisma `tours_owner_name_uniq`)
   * のみ。この制約に deleted_at の除外条件は無い (プレーンな unique index) ため、
   * 論理削除済みの同名ツアーとも衝突する — 事前チェックも deletedAt で絞らない。
   * 他の sync 対象コレクション (identities/memberships/events/applications/
   * application_companions) には owner スコープの unique 制約が無いため対応不要。
   */
  private async validateUniqueConstraints(
    client: SyncClient,
    collection: SyncCollection,
    userId: string,
    id: string,
    data: Record<string, unknown>,
  ): Promise<string | null> {
    if (collection !== 'tours') return null;

    const name = data.name;
    if (typeof name !== 'string') return null;

    const conflict = await client.tour.findFirst({
      where: { ownerId: userId, name, id: { not: id } },
    });
    if (conflict) {
      return 'tour name already exists';
    }

    return null;
  }

  private async upsertRecord(
    client: SyncClient,
    collection: SyncCollection,
    id: string,
    userId: string,
    data: Record<string, unknown>,
  ): Promise<void> {
    const create = { ...data, id, ownerId: userId };
    const update = { ...data, ownerId: userId };

    switch (collection) {
      case 'identities':
        await client.identity.upsert({
          where: { id },
          create: create as never,
          update: update as never,
        });
        return;
      case 'memberships':
        await client.membership.upsert({
          where: { id },
          create: create as never,
          update: update as never,
        });
        return;
      case 'tours':
        await client.tour.upsert({
          where: { id },
          create: create as never,
          update: update as never,
        });
        return;
      case 'events':
        await client.event.upsert({
          where: { id },
          create: create as never,
          update: update as never,
        });
        return;
      case 'applications':
        await client.application.upsert({
          where: { id },
          create: create as never,
          update: update as never,
        });
        return;
      case 'application_companions':
        await client.applicationCompanion.upsert({
          where: { id },
          create: create as never,
          update: update as never,
        });
    }
  }
}

function rejectFromAppError(id: string, error: AppError): SyncPushRejectedItem {
  const body = error.getResponse();
  const message =
    typeof body === 'object' &&
    body !== null &&
    'message' in body &&
    typeof (body as { message: unknown }).message === 'string'
      ? (body as { message: string }).message
      : error.code;
  return { id, code: error.code, message };
}
