import XCTest
import SwiftData
@testable import DataStore
import Domain

/// `SwiftDataMembershipRepository.delete`（会員情報単体削除）の連鎖処理の回帰テスト
/// （Issue #11 TE-2 / dT1 の `MembershipDeletionCascade` を membership 単体削除の入口から検証する）。
///
/// `SwiftDataIdentityRepositoryDeleteTests` が identity 削除経由の連鎖を検証するのに対し、
/// 本テストは membership を直接削除した場合の同じ不変条件を固定化する。製品コードは変更しない。
@MainActor
final class SwiftDataMembershipRepositoryDeleteCascadeTests: XCTestCase {
    /// `ApplicationRecord` はツアー/公演の存在を前提にしないので、テストでは直接 insert する。
    @discardableResult
    private func insertApplication(
        identityID: UUID,
        membershipID: UUID?,
        in context: ModelContext
    ) -> ApplicationRecord {
        let record = ApplicationRecord(
            id: UUID(),
            eventID: UUID(),
            repIdentityID: identityID,
            repMembershipID: membershipID,
            syncState: .synced
        )
        context.insert(record)
        return record
    }

    /// 会員情報削除で `deletedAt` が立ち、当該 membership を代表会員に持つ未削除 application の
    /// `repMembershipID` がクリアされ、その application も outbox に積まれる。
    func testDeleteSetsDeletedAtAndClearsReferencingApplicationRepMembership() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identityRepository = SwiftDataIdentityRepository(container: container)
        let membershipRepository = SwiftDataMembershipRepository(container: container)

        let identity = try await identityRepository.create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
        let membership = try await membershipRepository.create(
            Membership(identityID: identity.id, fanClubNameRaw: "FC A", memberNo: "1234")
        )

        let context = ModelContext(container)
        let application = insertApplication(identityID: identity.id, membershipID: membership.id, in: context)
        try context.save()

        try await membershipRepository.delete(id: membership.id)

        let verifyContext = ModelContext(container)
        let membershipRecord = try XCTUnwrap(try MembershipRecord.fetchRecord(id: membership.id, in: verifyContext))
        XCTAssertNotNil(membershipRecord.deletedAt, "会員情報に deletedAt が立つ")

        let applicationRecord = try XCTUnwrap(try ApplicationRecord.fetchRecord(id: application.id, in: verifyContext))
        XCTAssertNil(applicationRecord.deletedAt, "参照していた application 本体は削除されない")
        XCTAssertNil(applicationRecord.repMembershipID, "repMembershipID がクリアされる")

        let outbox = try verifyContext.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertEqual(outbox.filter { $0.collection == .memberships }.count, 1)
        XCTAssertTrue(
            outbox.contains { $0.targetID == application.id && $0.collection == .applications },
            "repMembershipID をクリアした application も outbox に積まれる"
        )
    }

    /// 会員情報削除後も、名義本体とその会員情報を参照していない他の application は残る。
    func testDeleteDoesNotTouchIdentityOrUnrelatedApplications() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identityRepository = SwiftDataIdentityRepository(container: container)
        let membershipRepository = SwiftDataMembershipRepository(container: container)

        let identity = try await identityRepository.create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
        let membership = try await membershipRepository.create(
            Membership(identityID: identity.id, fanClubNameRaw: "FC A")
        )

        let context = ModelContext(container)
        // repMembershipID を持たない application は影響を受けない。
        let unrelatedApplication = insertApplication(identityID: identity.id, membershipID: nil, in: context)
        try context.save()

        try await membershipRepository.delete(id: membership.id)

        let verifyContext = ModelContext(container)
        let identityRecord = try XCTUnwrap(try IdentityRecord.fetchRecord(id: identity.id, in: verifyContext))
        XCTAssertNil(identityRecord.deletedAt, "membership 削除で名義本体は削除されない")

        let unrelatedRecord = try XCTUnwrap(
            try ApplicationRecord.fetchRecord(id: unrelatedApplication.id, in: verifyContext)
        )
        XCTAssertNil(unrelatedRecord.deletedAt)
        XCTAssertNil(unrelatedRecord.repMembershipID)
    }

    /// 既に削除済み、または存在しない id への削除は `.notFound`。
    func testDeleteAlreadyDeletedOrUnknownIdIsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identityRepository = SwiftDataIdentityRepository(container: container)
        let membershipRepository = SwiftDataMembershipRepository(container: container)

        do {
            try await membershipRepository.delete(id: UUID())
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }

        let identity = try await identityRepository.create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
        let membership = try await membershipRepository.create(
            Membership(identityID: identity.id, fanClubNameRaw: "FC A")
        )
        try await membershipRepository.delete(id: membership.id)

        do {
            try await membershipRepository.delete(id: membership.id)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }
}
