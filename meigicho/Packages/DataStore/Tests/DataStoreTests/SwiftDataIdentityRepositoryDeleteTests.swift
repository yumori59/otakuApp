import XCTest
import SwiftData
@testable import DataStore
import Domain

/// 名義削除の連鎖処理（Issue #11 dT1）。
/// identity 削除 → 配下 membership の連鎖ソフトデリート → 当該 membership を代表会員に持つ
/// application の `repMembershipID` クリアを、同一 `ModelContext` / 同一 `save()` で検証する。
@MainActor
final class SwiftDataIdentityRepositoryDeleteTests: XCTestCase {
    /// `ApplicationRecord` はツアー/公演の存在を前提にしないので、テストでは直接 insert する
    /// （`SwiftDataApplicationRepository.create` の tour/event find-or-create は本テストの対象外）。
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

    func testDeleteCascadesToMembershipsAndClearsApplicationRepMembership() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identityRepository = SwiftDataIdentityRepository(container: container)
        let membershipRepository = SwiftDataMembershipRepository(container: container)

        let identity = try await identityRepository.create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
        let membership = try await membershipRepository.create(
            Membership(identityID: identity.id, fanClubNameRaw: "FC A", memberNoLast4: "1234")
        )

        // 削除される membership を代表会員として参照する未削除 application。
        let context = ModelContext(container)
        let application = insertApplication(identityID: identity.id, membershipID: membership.id, in: context)
        try context.save()

        try await identityRepository.delete(id: identity.id)

        let verifyContext = ModelContext(container)

        // identity 自体が論理削除される
        let identityRecord = try IdentityRecord.fetchRecord(id: identity.id, in: verifyContext)
        XCTAssertNotNil(identityRecord?.deletedAt)

        // 配下の membership も連鎖ソフトデリートされる
        let membershipRecord = try MembershipRecord.fetchRecord(id: membership.id, in: verifyContext)
        XCTAssertNotNil(membershipRecord?.deletedAt)

        // application 自体は削除されず、repMembershipID だけクリアされる
        let applicationRecord = try ApplicationRecord.fetchRecord(id: application.id, in: verifyContext)
        XCTAssertNil(applicationRecord?.deletedAt)
        XCTAssertNil(applicationRecord?.repMembershipID)

        // outbox に identities / memberships / applications の3種が積まれる
        let outbox = try verifyContext.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertEqual(outbox.filter { $0.collection == .identities }.count, 1)
        XCTAssertEqual(outbox.filter { $0.collection == .memberships }.count, 1)
        XCTAssertEqual(outbox.filter { $0.collection == .applications }.count, 1)
    }

    func testDeleteDoesNotTouchApplicationsReferencingOtherMemberships() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identityRepository = SwiftDataIdentityRepository(container: container)
        let membershipRepository = SwiftDataMembershipRepository(container: container)

        let identityA = try await identityRepository.create(
            Identity(displayName: "A", relation: .self, colorHex: "#0017C1")
        )
        let identityB = try await identityRepository.create(
            Identity(displayName: "B", relation: .other, colorHex: "#FF00AA")
        )
        let membershipB = try await membershipRepository.create(
            Membership(identityID: identityB.id, fanClubNameRaw: "FC B")
        )

        let context = ModelContext(container)
        let application = insertApplication(identityID: identityB.id, membershipID: membershipB.id, in: context)
        try context.save()

        try await identityRepository.delete(id: identityA.id)

        let verifyContext = ModelContext(container)
        let membershipRecord = try MembershipRecord.fetchRecord(id: membershipB.id, in: verifyContext)
        XCTAssertNil(membershipRecord?.deletedAt)

        let applicationRecord = try ApplicationRecord.fetchRecord(id: application.id, in: verifyContext)
        XCTAssertEqual(applicationRecord?.repMembershipID, membershipB.id)
    }

    func testDeleteAlreadyDeletedOrUnknownIdIsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataIdentityRepository(container: container)

        do {
            try await repository.delete(id: UUID())
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }

        let identity = try await repository.create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
        try await repository.delete(id: identity.id)

        do {
            try await repository.delete(id: identity.id)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }
}
