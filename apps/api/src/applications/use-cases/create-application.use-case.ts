import { Injectable } from '@nestjs/common';
import { AppError } from '../../common/errors/app-error';
import { EventsService } from '../../events/events.service';
import { IdentitiesService } from '../../identities/identities.service';
import { ToursService } from '../../tours/tours.service';
import { ApplicationResponse } from '../applications.presenter';
import { ApplicationsService } from '../applications.service';
import { CreateApplicationDto } from '../dto/create-application.dto';

/**
 * POST /v1/applications（api-contract.md §7）。
 * 単一トランザクションで tour find-or-create → event upsert → 所有検証 → 作成を行う。
 * 途中の 404 は TX ごとロールバックされる（AC-APP-04 / E-17）。
 * Prisma には直接触らず Service 経由でのみ読み書きする (BE-3 / ADR-009)。
 */
@Injectable()
export class CreateApplicationUseCase {
  constructor(
    private readonly applications: ApplicationsService,
    private readonly tours: ToursService,
    private readonly events: EventsService,
    private readonly identities: IdentitiesService,
  ) {}

  async execute(
    userId: string,
    dto: CreateApplicationDto,
  ): Promise<ApplicationResponse> {
    return this.applications.transaction(async (tx) => {
      // 0. 既存 id の再 POST は CONFLICT 409（副作用を出す前に検出する）
      if (dto.id) {
        const existing = await this.applications.findRawById(dto.id, tx);
        if (existing) {
          throw AppError.conflict(`application already exists: ${dto.id}`);
        }
      }

      // 1. tour: (owner_id, name) で find-or-create（ソフトデリート済みは復活）
      const tour = await this.tours.findOrCreateByName(userId, dto.tour, tx);

      // 2. event: id で upsert（ownerId / tourId はサーバー設定。他人のものは 404）
      const event = await this.events.upsertForApplication(
        userId,
        tour.id,
        dto.event,
        tx,
      );

      // 3. rep_identity_id の所有・未削除
      await this.identities.assertOwned(userId, dto.rep_identity_id, tx);

      // 4. rep_membership_id は rep_identity_id に属していること
      if (dto.rep_membership_id) {
        await this.applications.assertMembershipOwned(
          userId,
          dto.rep_membership_id,
          dto.rep_identity_id,
          tx,
        );
      }

      // 5. companions[].identity_id は非 null なら自分の未削除 identity
      for (const companion of dto.companions ?? []) {
        if (companion.identity_id) {
          await this.identities.assertOwned(userId, companion.identity_id, tx);
        }
      }

      // 6. application + companions
      return this.applications.create(userId, dto, event.id, tx);
    });
  }
}
