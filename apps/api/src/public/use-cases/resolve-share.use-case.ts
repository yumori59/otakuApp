import { Injectable } from '@nestjs/common';
import { ShareLink } from '@prisma/client';
import { AppError } from '../../common/errors/app-error';
import { ErrorCode } from '../../common/errors/error-codes';
import { EntitlementsService } from '../../entitlements/entitlements.service';
import { isShareActive } from '../../shares/share-validity';
import { SharesService } from '../../shares/shares.service';
import {
  TourMatrixInternalRow,
  TourMatrixService,
} from '../../tours/tour-matrix.service';
import { IdentitySummaryService } from '../identity-summary.service';
import {
  PublicSharePayload,
  TourShareRenderOptions,
  toIdentitySummaryPayload,
  toTourSharePayload,
} from '../public-share.presenter';
import { SharedApplicationsService } from '../shared-applications.service';

/**
 * GET /public/shares/:token（認証不要・api-contract.md §8）。
 *
 * - 未知 / 失効 / 期限切れ（期限ちょうどを含む）は**すべて同一の** `SHARE_INVALID` 404。
 *   存在有無・オーナー・スコープを message からも漏らさない（FR-SH-8 / E-8 / E-9）
 * - `view_count` を増やすのは有効な閲覧に成功したときだけ（AC-SH-13 / AC-SH-14）
 * - 出力の組み立てとマスキングは public-share.presenter.ts に集約
 * - `permission:"write"` のとき item に `item_key` / `rev` / `editable` が増える。
 *   `editable` は**閲覧のたびにオーナーの現在のプラン**で評価する（api-contract-delta.md §4）
 */
@Injectable()
export class ResolveShareUseCase {
  constructor(
    private readonly shares: SharesService,
    private readonly tourMatrix: TourMatrixService,
    private readonly summary: IdentitySummaryService,
    private readonly sharedApplications: SharedApplicationsService,
    private readonly entitlements: EntitlementsService,
  ) {}

  async execute(token: string): Promise<PublicSharePayload> {
    const now = new Date();
    const link = await this.shares.findByToken(token);
    if (!link || !isShareActive(link, now)) {
      throw shareInvalid();
    }

    const payload = await this.buildPayload(link, now);
    await this.shares.recordView(link.id, now);
    return payload;
  }

  private async buildPayload(
    link: ShareLink,
    now: Date,
  ): Promise<PublicSharePayload> {
    if (link.scopeType === 'tour') {
      // scope_id 欠損は壊れたリンク。存在を推測させずに SHARE_INVALID へ倒す
      if (!link.scopeId) throw shareInvalid();
      const { tour, rows } = await this.loadTourMatrix(
        link.ownerId,
        link.scopeId,
      );
      const options = await this.renderOptions(link, rows);
      return toTourSharePayload(tour, rows, now, options);
    }

    if (link.scopeType === 'identity_summary') {
      const rows = await this.summary.build(link.ownerId);
      return toIdentitySummaryPayload(rows, now);
    }

    // 未知の scope_type を別スコープに黙って落とさない（BE-2）。DB 不整合なので 500
    throw new AppError(ErrorCode.INTERNAL, 'unsupported share scope');
  }

  /**
   * read は追加情報なし。write のときだけ HMAC 鍵・公演数上限・updated_at を集める。
   * 未知の permission は黙って read に落とさず INTERNAL 500（DB 不整合 — BE-2）。
   */
  private async renderOptions(
    link: ShareLink,
    rows: TourMatrixInternalRow[],
  ): Promise<TourShareRenderOptions> {
    if (link.permission === 'read') return { permission: 'read' };
    if (link.permission !== 'write') {
      throw new AppError(ErrorCode.INTERNAL, 'unsupported share permission');
    }

    const [eventLimit, updatedAtByApplicationId] = await Promise.all([
      this.entitlements.shareWriteEventLimit(link.ownerId),
      rows.length === 0
        ? Promise.resolve(new Map<string, Date>())
        : this.sharedApplications.findUpdatedAtByTour(
            link.ownerId,
            link.scopeId as string,
          ),
    ]);

    return {
      permission: 'write',
      write: {
        tokenHash: link.tokenHash,
        eventLimit,
        updatedAtByApplicationId,
      },
    };
  }

  /**
   * 共有元 tour が削除済み / 見つからない場合の NOT_FOUND は
   * 内部 id を含む message ごと SHARE_INVALID に置き換える。
   */
  private async loadTourMatrix(ownerId: string, tourId: string) {
    try {
      return await this.tourMatrix.build(ownerId, tourId);
    } catch (error) {
      if (error instanceof AppError && error.code === ErrorCode.NOT_FOUND) {
        throw shareInvalid();
      }
      throw error;
    }
  }
}

function shareInvalid(): AppError {
  return new AppError(ErrorCode.SHARE_INVALID, 'share link is invalid');
}
