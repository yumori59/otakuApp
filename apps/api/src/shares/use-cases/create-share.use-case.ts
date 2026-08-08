import { Injectable } from '@nestjs/common';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { ToursService } from '../../tours/tours.service';
import { ShareRecipientsService } from '../share-recipients.service';
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
  ShareRecipientResponse,
  toShareCreatedResponse,
} from '../shares.presenter';
import { SharesService } from '../shares.service';

/**
 * POST /v1/shares（api-contract-delta.md §1）。
 * **判定順序（この順を変えない — AC-SI-13）**:
 * ① DTO 検証（形式・件数。ValidationPipe 済み） → ② self 判定 → ③ 実在確認
 * → ④ PLAN_LIMIT_SHARE → ⑤ PLAN_LIMIT_SHARE_WRITE → ⑥ 作成（share_links + share_recipients を 1 TX で）
 * Prisma には触らない (BE-3 / ADR-009)。
 */
@Injectable()
export class CreateShareUseCase {
  constructor(
    private readonly shares: SharesService,
    private readonly tours: ToursService,
    private readonly entitlements: EntitlementsService,
    private readonly shareRecipients: ShareRecipientsService,
  ) {}

  async execute(
    userId: string,
    dto: CreateShareDto,
  ): Promise<ShareCreatedResponse> {
    const permission = resolvePermission(dto);
    const scopeId = await this.resolveScopeId(userId, dto);
    const expiresAt = resolveExpiresAt(dto.expires_at);

    // ② self → ③ 実在確認（PLAN_LIMIT より前 — Free の打ち間違え原因を特定できるように）
    const accountIds = dedupe(dto.shared_with_account_ids);
    await this.assertNotSelf(userId, accountIds);
    const recipients = await this.assertKnownAccounts(accountIds);

    // ④ PLAN_LIMIT_SHARE → ⑤ PLAN_LIMIT_SHARE_WRITE
    await this.assertShareLimit(userId);
    if (permission === 'write' && scopeId) {
      await this.assertWriteEventLimit(userId, scopeId);
    }

    // ⑥ 作成
    const { row, token } = await this.shares.createWithRecipients(
      userId,
      {
        scopeType: dto.scope_type,
        scopeId,
        permission,
        maskMemberNo: dto.mask_member_no ?? true,
        expiresAt,
      },
      recipients.map((recipient) => ({
        accountId: recipient.accountId,
        userId: recipient.userId,
      })),
    );

    const recipientResponses: ShareRecipientResponse[] = recipients.map(
      (recipient) => ({
        account_id: recipient.accountId,
        display_name: recipient.displayName,
        invited_at: row.createdAt.toISOString(),
        last_viewed_at: null,
      }),
    );

    return toShareCreatedResponse(row, token, recipientResponses);
  }

  /** 呼び出し元自身の account_id を招待に含めていないか（AC-SI-06）。 */
  private async assertNotSelf(
    userId: string,
    accountIds: string[],
  ): Promise<void> {
    const ownAccountId = await this.shareRecipients.resolveOwnAccountId(
      userId,
    );
    if (ownAccountId && accountIds.includes(ownAccountId)) {
      throw new AppError(
        ErrorCode.SHARE_RECIPIENT_SELF,
        'cannot invite yourself',
      );
    }
  }

  /** 招待先が全て実在するか（AC-SI-02）。未知が 1 件でもあれば作成しない。 */
  private async assertKnownAccounts(accountIds: string[]) {
    const { resolved, unknown } = await this.shareRecipients.resolveAccountIds(
      accountIds,
    );
    if (unknown.length > 0) {
      throw new AppError(
        ErrorCode.SHARE_RECIPIENT_UNKNOWN,
        `unknown account ids: ${unknown.join(', ')}`,
        { unknown_account_ids: unknown },
      );
    }
    return resolved;
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

/**
 * 重複排除する（AC-SI-04。400 にしない）。
 * DTO を通らない経路の防御として、空/未指定も VALIDATION_ERROR 400 にする（AC-SI-01）。
 */
function dedupe(accountIds: string[] | undefined): string[] {
  if (!accountIds || accountIds.length === 0) {
    throw AppError.validation(
      'shared_with_account_ids must contain at least one account id',
    );
  }
  return [...new Set(accountIds)];
}
