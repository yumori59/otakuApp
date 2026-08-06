import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { ToursService } from '../../tours/tours.service';
import {
  CreateShareDto,
  DAY_MS,
  DEFAULT_EXPIRES_IN_DAYS,
  DEFAULT_SHARE_PERMISSION,
  MAX_EXPIRES_IN_DAYS,
  SHARE_PERMISSIONS,
  SharePermission,
} from '../dto/create-share.dto';
import {
  ShareCreatedResponse,
  toShareCreatedResponse,
} from '../shares.presenter';
import { SharesService } from '../shares.service';

/**
 * POST /v1/shares（api-contract.md §8）。
 * scope の所有検証 → プラン上限 → 発行 の順に行い、Prisma には触らない (BE-3 / ADR-009)。
 */
@Injectable()
export class CreateShareUseCase {
  constructor(
    private readonly shares: SharesService,
    private readonly tours: ToursService,
    private readonly entitlements: EntitlementsService,
    private readonly config: ConfigService,
  ) {}

  async execute(
    userId: string,
    dto: CreateShareDto,
  ): Promise<ShareCreatedResponse> {
    // 壊れた URL を返さないよう、設定不備は副作用を出す前に 500 にする
    const baseUrl = this.config.get<string>('SHARE_BASE_URL');
    if (!baseUrl) {
      throw new AppError(
        ErrorCode.INTERNAL,
        'SHARE_BASE_URL is not configured',
      );
    }

    const permission = resolvePermission(dto);
    const scopeId = await this.resolveScopeId(userId, dto);
    const expiresAt = resolveExpiresAt(dto.expires_at);
    await this.assertShareLimit(userId);
    // 本数上限 (PLAN_LIMIT_SHARE) の後に公演数上限を見る（plan.md 5.2）
    if (permission === 'write' && scopeId) {
      await this.assertWriteEventLimit(userId, scopeId);
    }

    const { row, token } = await this.shares.create(userId, {
      scopeType: dto.scope_type,
      scopeId,
      permission,
      maskMemberNo: dto.mask_member_no ?? true,
      sharedWithAccountIds: dto.shared_with_account_ids ?? [],
      expiresAt,
    });

    return toShareCreatedResponse(row, token, baseUrl);
  }

  /** tour スコープは自分の未削除 tour のみ（他人 / 未知は 404 — BE-4）。 */
  private async resolveScopeId(
    userId: string,
    dto: CreateShareDto,
  ): Promise<string | null> {
    if (dto.scope_type === 'tour') {
      if (!dto.scope_id) {
        throw AppError.validation('scope_id is required for scope_type=tour');
      }
      await this.tours.assertOwned(userId, dto.scope_id);
      return dto.scope_id;
    }

    if (dto.scope_id) {
      throw AppError.validation(
        'scope_id must not be sent when scope_type is identity_summary',
      );
    }
    return null;
  }

  /** free は同時有効リンク 1 本まで（Q7 / AC-SH-02）。plus は無制限。 */
  private async assertShareLimit(userId: string): Promise<void> {
    const limit = await this.entitlements.shareLimit(userId);
    if (limit === null) return;

    const current = await this.shares.countActive(userId, new Date());
    if (current >= limit) {
      throw new AppError(
        ErrorCode.PLAN_LIMIT_SHARE,
        `share limit reached (limit=${limit}, current=${current})`,
        { limit, current },
      );
    }
  }

  /**
   * write リンクは 1 本あたりの公演数に上限がある（free=3 / plus=無制限 — AC-SW-05）。
   * read リンクはこの制限を受けない。判定対象は未削除 event の件数（申込ゼロも数える）。
   */
  private async assertWriteEventLimit(
    userId: string,
    tourId: string,
  ): Promise<void> {
    const limit = await this.entitlements.shareWriteEventLimit(userId);
    if (limit === null) return;

    const current = await this.shares.countTourEvents(userId, tourId);
    if (current > limit) {
      throw new AppError(
        ErrorCode.PLAN_LIMIT_SHARE_WRITE,
        `share write event limit reached (limit=${limit}, current=${current})`,
        { limit, current },
      );
    }
  }
}

/**
 * DTO を通らない経路でも未知値を黙って read に落とさない（BE-2）。
 * `write` × `identity_summary` は DTO と同じく 400。
 */
function resolvePermission(dto: CreateShareDto): SharePermission {
  const permission = dto.permission ?? DEFAULT_SHARE_PERMISSION;
  if (!SHARE_PERMISSIONS.includes(permission)) {
    throw AppError.validation(
      `permission must be one of: ${SHARE_PERMISSIONS.join(', ')}`,
    );
  }
  if (permission === 'write' && dto.scope_type !== 'tour') {
    throw AppError.validation(
      'permission=write is only available for scope_type=tour',
    );
  }
  return permission;
}

/** 省略時は +30 日。上限 +365 日（DTO でも弾くが、ここでも守る）。 */
function resolveExpiresAt(raw: string | undefined): Date {
  const now = Date.now();
  if (!raw) return new Date(now + DEFAULT_EXPIRES_IN_DAYS * DAY_MS);

  const at = Date.parse(raw);
  if (Number.isNaN(at)) {
    throw AppError.validation('expires_at must be an ISO8601 datetime');
  }
  if (at > now + MAX_EXPIRES_IN_DAYS * DAY_MS) {
    throw AppError.validation(
      `expires_at must be within ${MAX_EXPIRES_IN_DAYS} days from now`,
    );
  }
  return new Date(at);
}
