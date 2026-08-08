import { Injectable } from '@nestjs/common';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { AddRecipientsDto } from '../dto/add-recipients.dto';
import { MAX_SHARED_WITH_ACCOUNT_IDS } from '../dto/create-share.dto';
import { ShareRecipientsService } from '../share-recipients.service';
import { isShareActive } from '../share-validity';
import { ShareRecipientResponse } from '../shares.presenter';
import { SharesService } from '../shares.service';

export interface AddRecipientsResult {
  recipients: ShareRecipientResponse[];
}

/**
 * POST /v1/shares/:id/recipients（api-contract-delta.md §3.1）。
 * 判定順序は `POST /v1/shares`（AC-SI-13）と同じ形: 他人/失効の id → self → 実在確認 → 合計20件上限 → 追加。
 * PLAN_LIMIT_SHARE / PLAN_LIMIT_SHARE_WRITE はここでは判定しない（追加は本数上限と無関係）。
 */
@Injectable()
export class AddRecipientsUseCase {
  constructor(
    private readonly shares: SharesService,
    private readonly shareRecipients: ShareRecipientsService,
  ) {}

  async execute(
    userId: string,
    shareId: string,
    dto: AddRecipientsDto,
  ): Promise<AddRecipientsResult> {
    // 他人の id / 失効・期限切れの id は 404（BE-4 / AC-SI-10 / AC-SI-11）
    const shareLink = await this.shares.findOwned(userId, shareId);
    if (!isShareActive(shareLink)) {
      throw AppError.notFound(`share not found: ${shareId}`);
    }

    const accountIds = dedupe(dto.account_ids);

    const ownAccountId =
      await this.shareRecipients.resolveOwnAccountId(userId);
    if (ownAccountId && accountIds.includes(ownAccountId)) {
      throw new AppError(
        ErrorCode.SHARE_RECIPIENT_SELF,
        'cannot invite yourself',
      );
    }

    const { resolved, unknown } =
      await this.shareRecipients.resolveAccountIds(accountIds);
    if (unknown.length > 0) {
      throw new AppError(
        ErrorCode.SHARE_RECIPIENT_UNKNOWN,
        `unknown account ids: ${unknown.join(', ')}`,
        { unknown_account_ids: unknown },
      );
    }

    // 既に招待済みの ACC-ID は冪等（invited_at を更新しない — AC-SI-08）。
    // 合計 20 件上限は「新規に増える分」だけで判定する。
    const existingAccountIds =
      await this.shareRecipients.accountIdsByShareLink(shareId);
    const newEntries = resolved.filter(
      (recipient) => !existingAccountIds.has(recipient.accountId),
    );
    const totalAfter = existingAccountIds.size + newEntries.length;
    if (totalAfter > MAX_SHARED_WITH_ACCOUNT_IDS) {
      throw AppError.validation(
        `recipients must not exceed ${MAX_SHARED_WITH_ACCOUNT_IDS} per share link (current=${existingAccountIds.size}, adding=${newEntries.length})`,
      );
    }

    await this.shareRecipients.addMany(
      shareId,
      newEntries.map((recipient) => ({
        accountId: recipient.accountId,
        userId: recipient.userId,
      })),
    );

    return {
      recipients: await this.shareRecipients.listByShareLink(shareId),
    };
  }
}

/**
 * 重複排除する（AC-SI-04 と同じ規約）。
 * DTO を通らない経路の防御として、空/未指定も VALIDATION_ERROR 400 にする。
 */
function dedupe(accountIds: string[] | undefined): string[] {
  if (!accountIds || accountIds.length === 0) {
    throw AppError.validation(
      'account_ids must contain at least one account id',
    );
  }
  return [...new Set(accountIds)];
}
