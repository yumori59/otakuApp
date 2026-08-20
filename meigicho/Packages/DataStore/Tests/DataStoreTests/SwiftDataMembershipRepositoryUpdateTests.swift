import XCTest
import SwiftData
@testable import DataStore
import Domain

/// `SwiftDataMembershipRepository.update` の回帰テスト（Issue #11 TE-2）。
/// 対象は既存実装（`SwiftDataMembershipRepository.swift:45-62`）。製品コードは変更せず、
/// 「outbox に1件積まれる」「部分更新で他フィールドが消えない」「削除済みへの更新は notFound」を固定化する。
@MainActor
final class SwiftDataMembershipRepositoryUpdateTests: XCTestCase {
    private func makeIdentity(_ container: ModelContainer) async throws -> Identity {
        let repository = SwiftDataIdentityRepository(container: container)
        return try await repository.create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
    }

    /// 更新で outbox に `memberships` が1件積まれる（create と重複しない）。
    func testUpdateEnqueuesOutboxEntryForMemberships() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let repository = SwiftDataMembershipRepository(container: container)
        let created = try await repository.create(
            Membership(identityID: identity.id, fanClubNameRaw: "FC A")
        )

        var patch = MembershipPatch()
        patch.rank = .set("プレミアム")
        _ = try await repository.update(id: created.id, patch)

        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertEqual(outbox.filter { $0.collection == .memberships }.count, 1)
    }

    /// FC名だけ変更しても `rank` / `autoRenew` / `note` は保持される（消えない）。
    func testUpdateOnlyFanClubNamePreservesOtherFields() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let repository = SwiftDataMembershipRepository(container: container)
        let created = try await repository.create(
            Membership(
                identityID: identity.id,
                fanClubNameRaw: "FC A",
                rank: "ゴールド",
                autoRenew: true,
                note: "既存メモ"
            )
        )

        var patch = MembershipPatch()
        patch.fanClubNameRaw = .set("FC A 改名")
        let updated = try await repository.update(id: created.id, patch)

        XCTAssertEqual(updated.fanClubNameRaw, "FC A 改名")
        XCTAssertEqual(updated.rank, "ゴールド", "触っていない rank は保持される")
        XCTAssertTrue(updated.autoRenew, "触っていない autoRenew は保持される")
        XCTAssertEqual(updated.note, "既存メモ", "触っていない note は保持される")
    }

    /// 削除済み会員情報への更新は `.notFound` で、新規行を作らない。
    func testUpdateDeletedMembershipThrowsNotFoundAndDoesNotCreateNewRow() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let repository = SwiftDataMembershipRepository(container: container)
        let created = try await repository.create(
            Membership(identityID: identity.id, fanClubNameRaw: "FC A")
        )
        try await repository.delete(id: created.id)

        var patch = MembershipPatch()
        patch.rank = .set("プレミアム")
        do {
            _ = try await repository.update(id: created.id, patch)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }

        let context = ModelContext(container)
        let allRecords = try context.fetch(FetchDescriptor<MembershipRecord>())
        XCTAssertEqual(allRecords.count, 1, "notFound で新規行は作られない")
    }
}
