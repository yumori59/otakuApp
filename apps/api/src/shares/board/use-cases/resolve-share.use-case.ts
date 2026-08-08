import { Injectable } from '@nestjs/common';
import { ShareLink } from '@prisma/client';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { EntitlementsService } from '../../../entitlements/entitlements.service';
import { SharesService } from '../../shares.service';
import {
  TourMatrixInternalRow,
  TourMatrixService,
} from '../../../tours/tour-matrix.service';
import { IdentitySummaryService } from '../identity-summary.service';
import {
  PublicSharePayload,
  TourShareRenderOptions,
  toIdentitySummaryPayload,
  toTourSharePayload,
} from '../public-share.presenter';
import { SharedApplicationsService } from '../shared-applications.service';

/**
 * `GET /v1/shares/received/:id` のペイロード組み立て（share-account-invites）。
 *
 * 旧 `GET /public/shares/:token` の token 起点の実装から、**呼び出し元が既に
 * 有効性・招待判定まで済ませた `ShareLink` 行を受け取る**形へ変更した
 * （api-contract-delta.md §4.2 ①〜④ は `shares/received/use-cases/get-board.use-case.ts`
 * / `redeem-share.use-case.ts` が担当。ここは⑤のペイロード組み立てのみ）。
 *
 * - `view_count` を増やすのはこの use case が呼ばれた（＝有効な閲覧が確定した）ときだけ
 * - 出力の組み立てとマスキングは public-share.presenter.ts に集約（NFR-7）
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

  /** `link` は呼び出し元が有効性・招待済みを確認済みの前提（BE-4）。 */
  async execute(link: ShareLink): Promise<PublicSharePayload> {
    const now = new Date();
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
