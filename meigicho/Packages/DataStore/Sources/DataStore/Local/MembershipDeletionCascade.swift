import Foundation
import SwiftData
import Domain

/// membership 削除に伴う共通の連鎖処理（Issue #11 dT1）。
///
/// BE `memberships.service.ts` の `remove`（156-165行）/ `update` の identity 付け替えと同じ不変条件
/// (`rep_membership.identity_id === rep_identity_id`, FR-AP-4) を守る:
/// 削除される membership を代表会員として参照している**未削除**の application は
/// `repMembershipID` を `nil` にクリアする（`deletedAt` は変えない）。
///
/// `SwiftDataIdentityRepository.delete`（名義削除 → 配下 membership の連鎖）と
/// `SwiftDataMembershipRepository.delete`（membership 単体削除）の両方から、
/// 呼び出し側の同一 `ModelContext` / 同一 `save()` の中で呼ばれる想定（呼び出し側は保存しない）。
enum MembershipDeletionCascade {
    static func clearApplicationsReferencing(
        membershipID: UUID,
        in context: ModelContext,
        now: Date
    ) throws {
        let descriptor = FetchDescriptor<ApplicationRecord>(
            predicate: #Predicate { $0.repMembershipID == membershipID && $0.deletedAt == nil }
        )
        for application in try context.fetch(descriptor) {
            application.repMembershipID = nil
            application.markDirty(now: now)
            OutboxQueue.enqueue(collection: .applications, targetID: application.id, in: context, now: now)
        }
    }
}
