import XCTest
import SwiftData
@testable import DataStore
import Domain
import Core

/// `SwiftDataCatalogRepository.updateTour` の回帰テスト（tour-edit-and-delete T2 / D-4）。
///
/// 対象は `SwiftDataCatalogRepository.swift` の `updateTour`。同名事前チェック（`deletedAt` を問わない・
/// 自分以外）と同値保存の無変更化を固定化する。tour / event / application はサーバー同様
/// `SwiftDataApplicationRepository.create` の find-or-create 経由でのみ作る（`SwiftDataCatalogRepository`
/// には作成メソッドが無い）。
@MainActor
final class SwiftDataCatalogRepositoryUpdateTourTests: XCTestCase {
    private func makeIdentity(_ container: ModelContainer, name: String = "本人") async throws -> Identity {
        let repository = SwiftDataIdentityRepository(container: container)
        return try await repository.create(
            Identity(displayName: name, relation: .self, colorHex: "#0017C1")
        )
    }

    private func draft(
        repIdentityID: UUID,
        tourName: String,
        artistNameRaw: String = "ARTIST",
        eventName: String = "東京公演"
    ) -> ApplicationDraft {
        ApplicationDraft(
            tour: TourDraft(name: tourName, artistNameRaw: artistNameRaw),
            event: EventDraft(name: eventName, venueNameRaw: "東京ドーム", eventDate: Date(timeIntervalSince1970: 1_800_000_000)),
            repIdentityID: repIdentityID,
            status: .applied,
            ticketCount: 2
        )
    }

    // MARK: - AC-TE-02

    /// 改名で `TourRecord.name` が変わり、outbox に `tours` のエントリが積まれる。
    func testUpdateTourRenameChangesNameAndEnqueuesOutbox() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let created = try await applications.create(draft(repIdentityID: identity.id, tourName: "ARENA TOUR 2026"))

        // 作成時に積まれた outbox エントリを取り除き、「更新で新たに積まれたか」を検証できるようにする
        // （`OutboxQueue.enqueue` は同一 targetID を upsert するため、無条件に count == 1 は作成時のエントリと区別できない）。
        let setupContext = ModelContext(container)
        try OutboxQueue.remove(targetID: created.tourID, in: setupContext)
        try setupContext.save()

        var patch = TourPatch()
        patch.name = .set("ARENA TOUR 2026 - FINAL")
        let updated = try await catalog.updateTour(id: created.tourID, patch)

        XCTAssertEqual(updated.name, "ARENA TOUR 2026 - FINAL")

        let context = ModelContext(container)
        let record = try XCTUnwrap(try TourRecord.fetchRecord(id: created.tourID, in: context))
        XCTAssertEqual(record.name, "ARENA TOUR 2026 - FINAL")

        let outbox = try context.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertEqual(
            outbox.filter { $0.collection == .tours && $0.targetID == created.tourID }.count,
            1,
            "改名で tours の outbox エントリが1件積まれる"
        )
    }

    // MARK: - AC-TE-03

    /// 改名しても配下 event / application の `updatedAt` と outbox は動かない。
    func testUpdateTourRenameDoesNotTouchEventOrApplication() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let created = try await applications.create(draft(repIdentityID: identity.id, tourName: "ARENA TOUR 2026"))

        let setupContext = ModelContext(container)
        try OutboxQueue.remove(targetID: created.eventID, in: setupContext)
        try OutboxQueue.remove(targetID: created.id, in: setupContext)
        try setupContext.save()

        let beforeContext = ModelContext(container)
        let eventBefore = try XCTUnwrap(try EventRecord.fetchRecord(id: created.eventID, in: beforeContext))
        let applicationBefore = try XCTUnwrap(try ApplicationRecord.fetchRecord(id: created.id, in: beforeContext))
        let eventUpdatedAtBefore = eventBefore.updatedAt
        let applicationUpdatedAtBefore = applicationBefore.updatedAt

        var patch = TourPatch()
        patch.name = .set("ARENA TOUR 2026 - FINAL")
        _ = try await catalog.updateTour(id: created.tourID, patch)

        let context = ModelContext(container)
        let eventAfter = try XCTUnwrap(try EventRecord.fetchRecord(id: created.eventID, in: context))
        let applicationAfter = try XCTUnwrap(try ApplicationRecord.fetchRecord(id: created.id, in: context))
        XCTAssertEqual(eventAfter.updatedAt, eventUpdatedAtBefore, "改名で event の updatedAt は動かない")
        XCTAssertEqual(applicationAfter.updatedAt, applicationUpdatedAtBefore, "改名で application の updatedAt は動かない")

        let outbox = try context.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertTrue(
            outbox.filter { $0.targetID == created.eventID }.isEmpty,
            "改名で event の outbox エントリは積まれない"
        )
        XCTAssertTrue(
            outbox.filter { $0.targetID == created.id }.isEmpty,
            "改名で application の outbox エントリは積まれない"
        )
    }

    // MARK: - AC-TE-04

    /// 既存の未削除ツアーと同名へのリネームは `.conflict` で失敗し、レコードは変わらない。
    func testUpdateTourRenameToExistingActiveNameThrowsConflict() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let tourA = try await applications.create(draft(repIdentityID: identity.id, tourName: "ARENA TOUR 2026"))
        _ = try await applications.create(draft(
            repIdentityID: identity.id,
            tourName: "DOME TOUR 2026",
            eventName: "大阪公演"
        ))

        var patch = TourPatch()
        patch.name = .set("DOME TOUR 2026")

        do {
            _ = try await catalog.updateTour(id: tourA.tourID, patch)
            XCTFail("expected conflict")
        } catch {
            XCTAssertEqual(error as? AppError, .conflict)
        }

        let context = ModelContext(container)
        let record = try XCTUnwrap(try TourRecord.fetchRecord(id: tourA.tourID, in: context))
        XCTAssertEqual(record.name, "ARENA TOUR 2026", "conflict 時はレコードが変わらない")
    }

    /// 論理削除済みツアーと同名へのリネームも `.conflict` で失敗する（`deletedAt` で絞らない = D-4）。
    func testUpdateTourRenameToExistingSoftDeletedNameThrowsConflict() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let tourA = try await applications.create(draft(repIdentityID: identity.id, tourName: "ARENA TOUR 2026"))
        let tourB = try await applications.create(draft(
            repIdentityID: identity.id,
            tourName: "DOME TOUR 2026",
            eventName: "大阪公演"
        ))

        let setupContext = ModelContext(container)
        let tourBRecord = try XCTUnwrap(try TourRecord.fetchRecord(id: tourB.tourID, in: setupContext))
        tourBRecord.softDelete()
        try setupContext.save()

        var patch = TourPatch()
        patch.name = .set("DOME TOUR 2026")

        do {
            _ = try await catalog.updateTour(id: tourA.tourID, patch)
            XCTFail("expected conflict")
        } catch {
            XCTAssertEqual(error as? AppError, .conflict)
        }

        let context = ModelContext(container)
        let record = try XCTUnwrap(try TourRecord.fetchRecord(id: tourA.tourID, in: context))
        XCTAssertEqual(record.name, "ARENA TOUR 2026", "conflict 時はレコードが変わらない")
    }

    // MARK: - AC-TE-05

    /// 元の名前・アーティスト名と同じ値で保存すると、`updatedAt` も outbox も動かない。
    func testUpdateTourSameValueDoesNotTouchUpdatedAtOrOutbox() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let created = try await applications.create(draft(
            repIdentityID: identity.id,
            tourName: "ARENA TOUR 2026",
            artistNameRaw: "ARTIST"
        ))

        let setupContext = ModelContext(container)
        try OutboxQueue.remove(targetID: created.tourID, in: setupContext)
        try setupContext.save()

        let beforeContext = ModelContext(container)
        let recordBefore = try XCTUnwrap(try TourRecord.fetchRecord(id: created.tourID, in: beforeContext))
        let updatedAtBefore = recordBefore.updatedAt

        var patch = TourPatch()
        patch.name = .set("ARENA TOUR 2026")
        patch.artistNameRaw = .set("ARTIST")
        let updated = try await catalog.updateTour(id: created.tourID, patch)

        XCTAssertEqual(updated.name, "ARENA TOUR 2026")

        let context = ModelContext(container)
        let recordAfter = try XCTUnwrap(try TourRecord.fetchRecord(id: created.tourID, in: context))
        XCTAssertEqual(recordAfter.updatedAt, updatedAtBefore, "同値保存で updatedAt は動かない")

        let outbox = try context.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertTrue(
            outbox.filter { $0.targetID == created.tourID }.isEmpty,
            "同値保存で outbox エントリは積まれない"
        )
    }

    // MARK: - AC-TE-10

    /// 論理削除済みの id への更新は `.notFound`。
    func testUpdateTourAlreadyDeletedThrowsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let created = try await applications.create(draft(repIdentityID: identity.id, tourName: "ARENA TOUR 2026"))

        let context = ModelContext(container)
        let record = try XCTUnwrap(try TourRecord.fetchRecord(id: created.tourID, in: context))
        record.softDelete()
        try context.save()

        var patch = TourPatch()
        patch.name = .set("ARENA TOUR 2026 - FINAL")

        do {
            _ = try await catalog.updateTour(id: created.tourID, patch)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    /// 存在しない id への更新は `.notFound`。
    func testUpdateTourNonexistentThrowsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let catalog = SwiftDataCatalogRepository(container: container)

        var patch = TourPatch()
        patch.name = .set("ARENA TOUR 2026 - FINAL")

        do {
            _ = try await catalog.updateTour(id: UUID(), patch)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }
}
