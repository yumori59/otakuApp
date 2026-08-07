import { Injectable, Logger } from '@nestjs/common';
import { Application, ShareLink } from '@prisma/client';
import { AppError } from '../../../common/errors/app-error';
import { ErrorCode } from '../../../common/errors/error-codes';
import { EntitlementsService } from '../../../entitlements/entitlements.service';
import { SharesService } from '../../shares.service';
import {
  TourMatrixInternalRow,
  TourMatrixService,
} from '../../../tours/tour-matrix.service';
import { UpdateShareItemDto } from '../dto/update-share-item.dto';
import {
  TourShareWriteItem,
  toTourShareWriteItem,
} from '../public-share.presenter';
import { handleEquals, shareItemKey, shareItemRev } from '../share-item-key';
import { ShareWriteContext, createShareItemAnnotator } from '../share-write';
import {
  SharedApplicationsService,
  SharedItemPatch,
} from '../shared-applications.service';

/**
 * `PATCH /v1/shares/received/:id/items/:item_key`（**Bearer 必須** / api-contract-delta.md §4.3）。
 *
 * **判定順序が契約**（この順番を変えない — AC-SI-29）:
 * ① `:id` 未知 / 失効 / 期限切れ                     → `SHARE_INVALID` 404
 * ② オーナー本人でなく、かつ招待リストに無い          → `SHARE_INVALID` 404
 * ③ `permission !== "write"`                        → `FORBIDDEN` 403
 * ④ `scope_type !== "tour"`                         → `FORBIDDEN` 403
 * ⑤ ボディ不正                                       → `VALIDATION_ERROR` 400（通常は ValidationPipe）
 * ⑥ `item_key` 不一致                                → `SHARE_INVALID` 404
 * ⑦ 対象行が `editable:false`                        → `FORBIDDEN` 403（**理由を区別しない**）
 * ⑧ `rev` 不一致                                     → `CONFLICT` 409（`details.current`）
 *
 * **①② は `shares/received/use-cases/update-item.use-case.ts` が担当する**（id 起点の解決と
 * 招待判定）。この use case は有効性・招待済みを確認済みの `ShareLink` を受け取り **③〜⑧ だけ**
 * を担当する。**② を ③ より後ろに置いてはならない** — 非招待者が 403 を受け取ると
 * 「そのリンクは read で実在する」ことが分かってしまう（plan.md D10 / AC-SI-29）。
 *
 * `item_key` / `rev` の HMAC 鍵は従来どおり `share_links.token_hash`。addressing が
 * `:token` → `:id` に変わっても鍵はサーバー内部にあるので変わらない。
 *
 * 失敗時は `applications` にも `share_links` にも一切書き込まない。
 * 成功時だけ `share_links.edit_count += 1` / `last_edited_at`（`view_count` は増やさない）。
 */
@Injectable()
export class UpdateShareItemUseCase {
  private readonly logger = new Logger(UpdateShareItemUseCase.name);

  constructor(
    private readonly shares: SharesService,
    private readonly tourMatrix: TourMatrixService,
    private readonly sharedApplications: SharedApplicationsService,
    private readonly entitlements: EntitlementsService,
  ) {}

  /** `link` は呼び出し元が①有効性・②招待済みを確認済みの前提（BE-4）。 */
  async execute(
    link: ShareLink,
    itemKey: string,
    dto: UpdateShareItemDto,
  ): Promise<TourShareWriteItem> {
    const now = new Date();

    // ③ 書き込み権限（read リンクは 403。未知の permission も write ではないので 403）
    if (link.permission !== 'write') throw forbidden();

    // ④ スコープ（write は tour のみ。DB 不整合も 403）
    if (link.scopeType !== 'tour' || !link.scopeId) throw forbidden();

    // ⑤ ボディ（ValidationPipe を通らない経路の防御）
    const patch = toPatch(dto);

    const { rows } = await this.loadRows(link.ownerId, link.scopeId);
    const context = await this.buildWriteContext(link);
    const annotate = createShareItemAnnotator(rows, context);

    // ⑥ item_key（他リンクの key / でたらめな key は 404。403 と区別しない）
    const target = rows.find((row) =>
      handleEquals(shareItemKey(link.tokenHash, row.application_id), itemKey),
    );
    if (!target) throw shareInvalid();

    const handles = annotate(target);

    // ⑦ editable（history_visible=false / 公演数超過のどちらかは判別できない）
    if (!handles.editable) throw forbidden();

    // ⑧ rev（クライアントが送ってきた値との照合）
    if (!handleEquals(handles.rev, dto.rev)) {
      throw conflict(target.status, target.seat_raw, handles.rev);
    }

    const expectedUpdatedAt = requireUpdatedAt(context, target.application_id);
    const updated = await this.sharedApplications.updateIfUnchanged(
      link.ownerId,
      target.application_id,
      expectedUpdatedAt,
      patch,
    );
    // ⑧' 条件付き更新が 0 件 = 読み取りから更新までの間に他者が更新した
    if (!updated) throw await this.conflictFromCurrent(link, target);

    await this.shares.recordEdit(link.id, now);
    // 変更キー名だけを残す（座席文字列などの値は出さない — AC-SW-28）
    this.logger.log(
      `share item updated: share_link_id=${link.id} application_id=${
        target.application_id
      } fields=${Object.keys(patch).sort().join(',')}`,
    );

    return this.toResponseItem(link, target, updated);
  }

  /** 共有元 tour が削除済み / 見つからない場合は内部 id ごと SHARE_INVALID に置き換える。 */
  private async loadRows(ownerId: string, tourId: string) {
    try {
      return await this.tourMatrix.build(ownerId, tourId);
    } catch (error) {
      if (error instanceof AppError && error.code === ErrorCode.NOT_FOUND) {
        throw shareInvalid();
      }
      throw error;
    }
  }

  /** editable / rev の判定材料。**閲覧時と同じくオーナーの現在のプラン**で評価する。 */
  private async buildWriteContext(link: ShareLink): Promise<ShareWriteContext> {
    const [eventLimit, updatedAtByApplicationId] = await Promise.all([
      this.entitlements.shareWriteEventLimit(link.ownerId),
      this.sharedApplications.findUpdatedAtByTour(
        link.ownerId,
        link.scopeId as string,
      ),
    ]);
    return { tokenHash: link.tokenHash, eventLimit, updatedAtByApplicationId };
  }

  /** 同時更新。現在値を読み直して `details.current` に載せる（行が消えていたら 404）。 */
  private async conflictFromCurrent(
    link: ShareLink,
    target: TourMatrixInternalRow,
  ): Promise<AppError> {
    const current = await this.sharedApplications.findOwned(
      link.ownerId,
      target.application_id,
    );
    if (!current) return shareInvalid();
    return conflict(
      current.status,
      current.seatRaw,
      shareItemRev(link.tokenHash, current.id, current.updatedAt),
    );
  }

  /** 更新後の 1 件。GET の items 要素と同形（マスキングは presenter に集約）。 */
  private toResponseItem(
    link: ShareLink,
    target: TourMatrixInternalRow,
    updated: Application,
  ): TourShareWriteItem {
    return toTourShareWriteItem(
      { ...target, status: updated.status, seat_raw: updated.seatRaw },
      {
        item_key: shareItemKey(link.tokenHash, updated.id),
        rev: shareItemRev(link.tokenHash, updated.id, updated.updatedAt),
        editable: true,
      },
    );
  }
}

/** DTO で受けた 2 キーだけを Prisma の列名に写す（他の列は共有先に開放しない）。 */
function toPatch(dto: UpdateShareItemDto): SharedItemPatch {
  const patch: SharedItemPatch = {};
  if (dto.status !== undefined) patch.status = dto.status;
  if (dto.seat !== undefined) patch.seatRaw = dto.seat;
  if (Object.keys(patch).length === 0) {
    throw AppError.validation('at least one of status / seat is required');
  }
  return patch;
}

function requireUpdatedAt(
  context: ShareWriteContext,
  applicationId: string,
): Date {
  const updatedAt = context.updatedAtByApplicationId.get(applicationId);
  if (!updatedAt) {
    throw new AppError(
      ErrorCode.INTERNAL,
      'shared item revision is unavailable',
    );
  }
  return updatedAt;
}

/** 存在有無・オーナー・スコープを message からも漏らさない（GET と同一文言）。 */
function shareInvalid(): AppError {
  return new AppError(ErrorCode.SHARE_INVALID, 'share link is invalid');
}

/** read リンク / editable:false のどちらも同じ 403（理由を区別しない）。 */
function forbidden(): AppError {
  return new AppError(ErrorCode.FORBIDDEN, 'share item is not editable');
}

function conflict(status: string, seat: string | null, rev: string): AppError {
  return AppError.conflict('share item was updated by someone else', {
    current: { status, seat, rev },
  });
}
