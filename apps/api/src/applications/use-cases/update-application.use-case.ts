import { Injectable } from '@nestjs/common';
import { IdentitiesService } from '../../identities/identities.service';
import { ApplicationResponse } from '../applications.presenter';
import { ApplicationsService } from '../applications.service';
import { UpdateApplicationDto } from '../dto/update-application.dto';

/**
 * PATCH /v1/applications/:id（api-contract.md §7）。
 * 所有検証 → 参照先検証 → スカラー更新 → companions 全置換を単一 TX で行う。
 * `event_id` / `tour_id` の付け替えは DTO 側で 400（AC-APP-14）。
 */
@Injectable()
export class UpdateApplicationUseCase {
  constructor(
    private readonly applications: ApplicationsService,
    private readonly identities: IdentitiesService,
  ) {}

  async execute(
    userId: string,
    id: string,
    dto: UpdateApplicationDto,
  ): Promise<ApplicationResponse> {
    return this.applications.transaction(async (tx) => {
      const current = await this.applications.assertOwned(userId, id, tx);

      if (dto.rep_identity_id !== undefined) {
        await this.identities.assertOwned(userId, dto.rep_identity_id, tx);
      }

      // membership は「更新後の」代表名義に属している必要がある (FR-AP-4)
      let effectiveDto = dto;
      if (dto.rep_membership_id) {
        const repIdentityId = dto.rep_identity_id ?? current.repIdentityId;
        await this.applications.assertMembershipOwned(
          userId,
          dto.rep_membership_id,
          repIdentityId,
          tx,
        );
      } else if (
        dto.rep_membership_id === undefined &&
        dto.rep_identity_id !== undefined &&
        dto.rep_identity_id !== current.repIdentityId &&
        current.repMembershipId
      ) {
        // rep_identity_id だけ付け替えると旧名義の会員資格が残り不変条件が破れる。
        // クライアントに会員 ID まで意識させないため、属さなくなった参照は自動クリアする。
        const stillOwned = await this.applications.findMembershipOwned(
          userId,
          current.repMembershipId,
          dto.rep_identity_id,
          tx,
        );
        if (!stillOwned) {
          effectiveDto = { ...dto, rep_membership_id: null };
        }
      }

      for (const companion of dto.companions ?? []) {
        if (companion.identity_id) {
          await this.identities.assertOwned(userId, companion.identity_id, tx);
        }
      }

      return this.applications.applyUpdate(userId, id, effectiveDto, tx);
    });
  }
}
