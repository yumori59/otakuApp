import XCTest
import SwiftData
@testable import DataStore
import Domain
import Core

/// `SwiftDataCatalogRepository.deleteTour` の回帰テスト（tour-edit-and-delete T3 / D-5）。
///
/// 対象は `SwiftDataCatalogRepository.swift` の `deleteTour`。tour → event → application → companion の
/// 連鎖ソフトデリート・outbox 4 コレクション・identity / membership の非連鎖・存在しない/削除済み id での
/// `.notFound` を固定化する。
@MainActor
final class SwiftDataCatalogRepositoryDeleteTourTests: XCTestCase {
    private func makeIdentity(_ container: ModelContainer, name: String = "本人") async throws -> Identity {
        let repository = SwiftDataIdentityRepository(container: container)
        return try await repository.create(
            Identity(displayName: name, relation: .self, colorHex: "#0017C1")
        )
    }

    private func makeMembership(_ container: ModelContainer, identityID: UUID) async throws -> Membership {
        let repository = SwiftDataMembershipRepository(container: container)
        return try await repository.create(
            Membership(identityID: identityID, fanClubNameRaw: "FC本会")
        )
    }

    private func draft(
        repIdentityID: UUID,
        repMembershipID: UUID? = nil,
        tourName: String = "ARENA TOUR 2026",
        eventName: String = "東京公演",
        companions: [Companion] = []
    ) -> ApplicationDraft {
        ApplicationDraft(
            tour: TourDraft(name: tourName, artistNameRaw: "ARTIST"),
            event: EventDraft(name: eventName, venueNameRaw: "東京ドーム", eventDate: Date(timeIntervalSince1970: 1_800_000_000)),
            repIdentityID: repIdentityID,
            repMembershipID: repMembershipID,
            status: .applied,
            ticketCount: 2,
            companions: companions
        )
    }

    // MARK: - AC-TE-07

    /// ツアー削除で、tour 本体・配下 event・配下 application・配下 companion すべてに `deletedAt` が立つ。
    func testDeleteTourCascadesDeletedAtToEventsApplicationsAndCompanions() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let companion = Companion(displayName: "同行者A", position: 0)
        let created = try await applications.create(draft(repIdentityID: identity.id, companions: [companion]))

        try await catalog.deleteTour(id: created.tourID)

        let context = ModelContext(container)
        let tourRecord = try XCTUnwrap(try TourRecord.fetchRecord(id: created.tourID, in: context))
        XCTAssertNotNil(tourRecord.deletedAt, "tour 本体に deletedAt が立つ")

        let eventRecord = try XCTUnwrap(try EventRecord.fetchRecord(id: created.eventID, in: context))
        XCTAssertNotNil(eventRecord.deletedAt, "配下 event に deletedAt が立つ")

        let applicationRecord = try XCTUnwrap(try ApplicationRecord.fetchRecord(id: created.id, in: context))
        XCTAssertNotNil(applicationRecord.deletedAt, "配下 application に deletedAt が立つ")

        let companionRecords = try ApplicationCompanionRecord.fetchAll(applicationID: created.id, in: context)
        XCTAssertEqual(companionRecords.count, 1)
        XCTAssertNotNil(companionRecords.first?.deletedAt, "配下 companion に deletedAt が立つ")
    }

    // MARK: - AC-TE-08

    /// outbox に tours / events / applications / application_companions の4コレクション分が積まれる。
    func testDeleteTourEnqueuesOutboxForAllFourCollections() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let companion = Companion(displayName: "同行者A", position: 0)
        let created = try await applications.create(draft(repIdentityID: identity.id, companions: [companion]))

        try await catalog.deleteTour(id: created.tourID)

        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxEntry>())

        XCTAssertTrue(
            outbox.contains { $0.targetID == created.tourID && $0.collection == .tours },
            "tours の outbox エントリが積まれる"
        )
        XCTAssertTrue(
            outbox.contains { $0.targetID == created.eventID && $0.collection == .events },
            "events の outbox エントリが積まれる"
        )
        XCTAssertTrue(
            outbox.contains { $0.targetID == created.id && $0.collection == .applications },
            "applications の outbox エントリが積まれる"
        )
        XCTAssertTrue(
            outbox.contains { $0.targetID == companion.id && $0.collection == .applicationCompanions },
            "application_companions の outbox エントリが積まれる"
        )
    }

    // MARK: - AC-TE-09

    /// ツアー削除に使った申込の代表 identity / membership は消えない（連鎖対象外）。
    func testDeleteTourDoesNotCascadeToIdentityOrMembership() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let membership = try await makeMembership(container, identityID: identity.id)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let created = try await applications.create(
            draft(repIdentityID: identity.id, repMembershipID: membership.id)
        )

        try await catalog.deleteTour(id: created.tourID)

        let context = ModelContext(container)
        let identityRecord = try XCTUnwrap(try IdentityRecord.fetchRecord(id: identity.id, in: context))
        XCTAssertNil(identityRecord.deletedAt, "ツアー削除で名義は削除されない")

        let membershipRecord = try XCTUnwrap(try MembershipRecord.fetchRecord(id: membership.id, in: context))
        XCTAssertNil(membershipRecord.deletedAt, "ツアー削除で会員情報は削除されない")
    }

    // MARK: - AC-TE-10

    /// 既に削除済みの tour id への削除は `.notFound`。
    func testDeleteTourAlreadyDeletedThrowsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let created = try await applications.create(draft(repIdentityID: identity.id))

        try await catalog.deleteTour(id: created.tourID)

        do {
            try await catalog.deleteTour(id: created.tourID)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    /// 存在しない tour id への削除は `.notFound`。
    func testDeleteTourNonexistentThrowsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let catalog = SwiftDataCatalogRepository(container: container)

        do {
            try await catalog.deleteTour(id: UUID())
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    // MARK: - 他ツアーへの波及なし

    /// 削除対象外のツアーの event / application は影響を受けない。
    func testDeleteTourDoesNotAffectOtherTour() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let target = try await applications.create(draft(repIdentityID: identity.id, tourName: "ARENA TOUR 2026"))
        let other = try await applications.create(draft(
            repIdentityID: identity.id,
            tourName: "DOME TOUR 2026",
            eventName: "大阪公演"
        ))

        try await catalog.deleteTour(id: target.tourID)

        let context = ModelContext(container)
        let otherTourRecord = try XCTUnwrap(try TourRecord.fetchRecord(id: other.tourID, in: context))
        XCTAssertNil(otherTourRecord.deletedAt, "別ツアーは削除されない")

        let otherEventRecord = try XCTUnwrap(try EventRecord.fetchRecord(id: other.eventID, in: context))
        XCTAssertNil(otherEventRecord.deletedAt, "別ツアーの event は削除されない")

        let otherApplicationRecord = try XCTUnwrap(try ApplicationRecord.fetchRecord(id: other.id, in: context))
        XCTAssertNil(otherApplicationRecord.deletedAt, "別ツアーの application は削除されない")
    }
}
