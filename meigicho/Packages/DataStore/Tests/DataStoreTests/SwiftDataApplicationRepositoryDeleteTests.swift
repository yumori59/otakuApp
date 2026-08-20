import XCTest
import SwiftData
@testable import DataStore
import Domain
import Core

/// 申込削除（`SwiftDataApplicationRepository.delete`）の回帰テスト。
///
/// 対象は既存実装（`SwiftDataApplicationRepository.swift:194-209`）で、companions への連鎖ソフトデリートも
/// 既に実装済みの前提。このテストは製品コードを変更せず、その挙動を固定化する。
@MainActor
final class SwiftDataApplicationRepositoryDeleteTests: XCTestCase {
    private func makeIdentity(_ container: ModelContainer, name: String = "本人") async throws -> Identity {
        let repository = SwiftDataIdentityRepository(container: container)
        return try await repository.create(
            Identity(displayName: name, relation: .self, colorHex: "#0017C1")
        )
    }

    private func draft(repIdentityID: UUID, tourName: String = "ARENA TOUR 2026", companions: [Companion] = []) -> ApplicationDraft {
        ApplicationDraft(
            tour: TourDraft(name: tourName, artistNameRaw: "ARTIST"),
            event: EventDraft(name: "東京公演", venueNameRaw: "東京ドーム", eventDate: Date(timeIntervalSince1970: 1_800_000_000)),
            repIdentityID: repIdentityID,
            status: .applied,
            ticketCount: 2,
            companions: companions
        )
    }

    /// 申込削除で、申込本体と同行者の両方に `deletedAt` が立つ。
    func testDeleteSetsDeletedAtOnApplicationAndCompanions() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let companion = Companion(displayName: "同行者A", position: 0)
        let created = try await applications.create(draft(repIdentityID: identity.id, companions: [companion]))

        try await applications.delete(id: created.id)

        let context = ModelContext(container)
        let applicationRecord = try XCTUnwrap(try ApplicationRecord.fetchRecord(id: created.id, in: context))
        XCTAssertNotNil(applicationRecord.deletedAt, "申込本体に deletedAt が立つ")

        let companionRecords = try ApplicationCompanionRecord.fetchAll(applicationID: created.id, in: context)
        XCTAssertEqual(companionRecords.count, 1)
        XCTAssertNotNil(companionRecords.first?.deletedAt, "同行者にも deletedAt が立つ")
    }

    /// outbox に applications と applicationCompanions の両方が積まれる。
    func testDeleteEnqueuesOutboxForApplicationAndCompanions() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let companion = Companion(displayName: "同行者A", position: 0)
        let created = try await applications.create(draft(repIdentityID: identity.id, companions: [companion]))

        try await applications.delete(id: created.id)

        let context = ModelContext(container)
        let outbox = try context.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertTrue(
            outbox.contains { $0.targetID == created.id && $0.collection == .applications },
            "applications の outbox エントリが積まれる"
        )
        XCTAssertTrue(
            outbox.contains { $0.targetID == companion.id && $0.collection == .applicationCompanions },
            "applicationCompanions の outbox エントリが積まれる"
        )
    }

    /// 申込削除後も、その申込が参照していた tour / event のレコードは削除されず残る。
    func testDeleteDoesNotCascadeToTourOrEvent() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let created = try await applications.create(draft(repIdentityID: identity.id))

        try await applications.delete(id: created.id)

        let context = ModelContext(container)
        let tourRecord = try XCTUnwrap(try TourRecord.fetchRecord(id: created.tourID, in: context))
        XCTAssertNil(tourRecord.deletedAt, "申込削除でツアーは削除されない")

        let eventRecord = try XCTUnwrap(try EventRecord.fetchRecord(id: created.eventID, in: context))
        XCTAssertNil(eventRecord.deletedAt, "申込削除で公演は削除されない")
    }

    /// 既に削除済みの id への削除は `.notFound` を返す。
    func testDeleteAlreadyDeletedThrowsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let created = try await applications.create(draft(repIdentityID: identity.id))

        try await applications.delete(id: created.id)

        do {
            try await applications.delete(id: created.id)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    /// 存在しない id への削除は `.notFound` を返す。
    func testDeleteNonexistentThrowsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let applications = SwiftDataApplicationRepository(container: container)

        do {
            try await applications.delete(id: UUID())
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }
}
