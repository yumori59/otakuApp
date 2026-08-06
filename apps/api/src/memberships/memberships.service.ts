import { Injectable } from '@nestjs/common';
import { Membership, Prisma } from '@prisma/client';
import { AppError } from '../common/errors/app-error';
import { fromDateOnly, toDateOnly } from '../common/util/date.util';
import { IdentitiesService } from '../identities/identities.service';
import { PrismaService } from '../prisma/prisma.service';
import { CreateMembershipDto } from './dto/create-membership.dto';
import { UpdateMembershipDto } from './dto/update-membership.dto';

/** api-contract.md §4 の membership レスポンス要素（snake_case）。 */
export interface MembershipResponse {
  id: string;
  identity_id: string;
  fan_club_name_raw: string;
  member_no_last4: string | null;
  rank: string | null;
  renewal_on: string | null;
  fee_yen: number | null;
  auto_renew: boolean;
  note: string | null;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

/**
 * 会員資格 (memberships) のドメイン・認可 (ownerId)・Prisma アクセス (ADR-009)。
 * 親 identity の所有検証は IdentitiesService.assertOwned に委譲する（BE-4, FR-MB-2）。
 */
@Injectable()
export class MembershipsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly identities: IdentitiesService,
  ) {}

  async list(userId: string, identityId?: string): Promise<MembershipResponse[]> {
    if (identityId) {
      await this.identities.assertOwned(userId, identityId);
    }
    const rows = await this.prisma.membership.findMany({
      where: identityId
        ? { ownerId: userId, identityId, deletedAt: null }
        : { ownerId: userId, deletedAt: null },
      orderBy: [
        { renewalOn: { sort: 'asc', nulls: 'last' } },
        { createdAt: 'asc' },
      ],
    });
    return rows.map(toMembershipResponse);
  }

  async get(userId: string, id: string): Promise<MembershipResponse> {
    const row = await this.findOwned(userId, id);
    return toMembershipResponse(row);
  }

  async create(
    userId: string,
    dto: CreateMembershipDto,
  ): Promise<MembershipResponse> {
    await this.identities.assertOwned(userId, dto.identity_id);

    // 既存 id への再 POST は CONFLICT 409（identities.create と同形 / BE-6）
    const existing = await this.prisma.membership.findUnique({
      where: { id: dto.id },
    });
    if (existing) {
      throw AppError.conflict(`membership already exists: ${dto.id}`);
    }

    const created = await this.prisma.membership.create({
      data: {
        id: dto.id,
        ownerId: userId,
        identityId: dto.identity_id,
        fanClubNameRaw: dto.fan_club_name_raw,
        memberNoLast4: dto.member_no_last4 ?? null,
        rank: dto.rank ?? null,
        renewalOn: dto.renewal_on ? toDateOnly(dto.renewal_on) : null,
        feeYen: dto.fee_yen ?? null,
        autoRenew: dto.auto_renew ?? false,
        note: dto.note ?? null,
      },
    });
    return toMembershipResponse(created);
  }

  async update(
    userId: string,
    id: string,
    dto: UpdateMembershipDto,
  ): Promise<MembershipResponse> {
    const current = await this.findOwned(userId, id);

    if (dto.identity_id !== undefined) {
      await this.identities.assertOwned(userId, dto.identity_id);
    }
    const nextIdentityId =
      dto.identity_id !== undefined && dto.identity_id !== current.identityId
        ? dto.identity_id
        : null;

    const data: Prisma.MembershipUncheckedUpdateInput = {};
    if (dto.identity_id !== undefined) data.identityId = dto.identity_id;
    if (dto.fan_club_name_raw !== undefined) {
      data.fanClubNameRaw = dto.fan_club_name_raw;
    }
    if (dto.member_no_last4 !== undefined) {
      data.memberNoLast4 = dto.member_no_last4;
    }
    if (dto.rank !== undefined) data.rank = dto.rank;
    if (dto.renewal_on !== undefined) {
      data.renewalOn = dto.renewal_on === null ? null : toDateOnly(dto.renewal_on);
    }
    if (dto.fee_yen !== undefined) data.feeYen = dto.fee_yen;
    if (dto.auto_renew !== undefined) data.autoRenew = dto.auto_renew;
    if (dto.note !== undefined) data.note = dto.note;

    if (nextIdentityId === null) {
      const updated = await this.prisma.membership.update({ where: { id }, data });
      return toMembershipResponse(updated);
    }

    // identity を付け替えると、この membership を代表会員として参照している
    // application の不変条件 (`rep_membership.identity_id === rep_identity_id`,
    // FR-AP-4) が破れる。移動先の名義と一致しない参照は同一 TX でクリアする。
    const updated = await this.prisma.$transaction(async (tx) => {
      const row = await tx.membership.update({ where: { id }, data });
      await tx.application.updateMany({
        where: {
          ownerId: userId,
          repMembershipId: id,
          deletedAt: null,
          repIdentityId: { not: nextIdentityId },
        },
        data: { repMembershipId: null },
      });
      return row;
    });
    return toMembershipResponse(updated);
  }

  /** ソフトデリート。冪等（既に削除済みでも成功）。他人 / 存在しない id は 404。 */
  async remove(userId: string, id: string): Promise<void> {
    const existing = await this.prisma.membership.findFirst({
      where: { id, ownerId: userId },
    });
    if (!existing) {
      throw AppError.notFound(`membership not found: ${id}`);
    }
    if (existing.deletedAt) return;

    // 削除される membership を代表会員として参照している application が残ると
    // FR-AP-4 の不変条件が破れる（update() の identity 付け替えと同じ理由）。
    await this.prisma.$transaction(async (tx) => {
      await tx.membership.update({
        where: { id },
        data: { deletedAt: new Date() },
      });
      await tx.application.updateMany({
        where: { ownerId: userId, repMembershipId: id, deletedAt: null },
        data: { repMembershipId: null },
      });
    });
  }

  private async findOwned(userId: string, id: string): Promise<Membership> {
    const row = await this.prisma.membership.findFirst({
      where: { id, ownerId: userId, deletedAt: null },
    });
    if (!row) {
      throw AppError.notFound(`membership not found: ${id}`);
    }
    return row;
  }
}

function toMembershipResponse(row: Membership): MembershipResponse {
  return {
    id: row.id,
    identity_id: row.identityId,
    fan_club_name_raw: row.fanClubNameRaw,
    member_no_last4: row.memberNoLast4,
    rank: row.rank,
    renewal_on: fromDateOnly(row.renewalOn),
    fee_yen: row.feeYen,
    auto_renew: row.autoRenew,
    note: row.note,
    created_at: row.createdAt.toISOString(),
    updated_at: row.updatedAt.toISOString(),
    deleted_at: row.deletedAt ? row.deletedAt.toISOString() : null,
  };
}
