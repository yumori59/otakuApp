import XCTest
import SwiftData
@testable import DataStore
import Domain

@MainActor
final class SwiftDataMembershipRepositoryTests: XCTestCase {
    private func makeIdentity(_ container: ModelContainer) async throws -> Identity {
        let repository = SwiftDataIdentityRepository(container: container)
        return try await repository.create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
    }

    func testCreateUpdateDeleteEnqueuesOutbox() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let repository = SwiftDataMembershipRepository(container: container)

        let created = try await repository.create(
            Membership(identityID: identity.id, fanClubNameRaw: "FC A", memberNo: "1234", feeYen: 4400)
        )
        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 1)
        let pendingAfterCreate = try await repository.pendingCount()
        XCTAssertEqual(pendingAfterCreate, 1)

        var patch = MembershipPatch()
        patch.rank = .set("プレミアム")
        patch.feeYen = .set(nil)
        let updated = try await repository.update(id: created.id, patch)
        XCTAssertEqual(updated.rank, "プレミアム")
        XCTAssertNil(updated.feeYen)

        try await repository.delete(id: created.id)
        let afterDelete = try await repository.list()
        XCTAssertTrue(afterDelete.isEmpty)

        // ソフトデリート行は push 待ちとして残る（AC-SY-04）
        let pendingAfterDelete = try await repository.pendingCount()
        XCTAssertEqual(pendingAfterDelete, 1)
        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertEqual(outbox.filter { $0.collection == .memberships }.count, 1)
    }

    func testCreateRejectsUnknownIdentity() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataMembershipRepository(container: container)
        do {
            _ = try await repository.create(Membership(identityID: UUID(), fanClubNameRaw: "FC"))
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    func testSyncPayloadUsesSnakeCaseContract() throws {
        let record = MembershipRecord(
            id: UUID(),
            identityID: UUID(),
            fanClubNameRaw: "FC A",
            memberNo: nil,
            rank: nil,
            renewalOn: nil,
            feeYen: nil,
            autoRenew: true,
            note: ""
        )
        let payload = record.syncPayload()
        XCTAssertEqual(payload["fan_club_name_raw"], .string("FC A"))
        XCTAssertEqual(payload["auto_renew"], .bool(true))
        // 未設定は「送らない」ではなく明示的 null（サーバー mapper が `?? null` で受ける）
        XCTAssertEqual(payload["member_no"], .null)
        XCTAssertEqual(payload["renewal_on"], .null)
        XCTAssertEqual(payload["fee_yen"], .null)
        XCTAssertEqual(payload["note"], .null)
        XCTAssertEqual(payload["deleted_at"], .null)
    }
}
