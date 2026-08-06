import XCTest
import SwiftData
@testable import DataStore
import Domain
import Core

@MainActor
final class SwiftDataApplicationRepositoryTests: XCTestCase {
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

    func testCreateFindsOrCreatesTourAndEvent() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let first = try await applications.create(draft(repIdentityID: identity.id))
        let second = try await applications.create(draft(repIdentityID: identity.id))

        // 同名ツアーは 1 件に寄る（BE の (owner_id, name) find-or-create と同じ）
        let tours = try await catalog.listTours()
        XCTAssertEqual(tours.count, 1)
        XCTAssertEqual(first.tourID, second.tourID)
        XCTAssertEqual(first.tourID, tours[0].id)
        XCTAssertNotEqual(first.eventID, second.eventID)

        let page = try await applications.listPage(limit: 10, cursor: nil)
        XCTAssertEqual(page.items.count, 2)
        XCTAssertFalse(page.hasMore)
    }

    func testCreateRejectsMoreThanThreeCompanions() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)

        let companions = (0..<4).map { Companion(displayName: "同行\($0)", position: $0) }
        do {
            _ = try await applications.create(draft(repIdentityID: identity.id, companions: companions))
            XCTFail("expected validation error")
        } catch {
            guard case .validation = (error as? AppError) else {
                return XCTFail("expected validation, got \(error)")
            }
        }
    }

    func testUpdateReplacesCompanionsAndSoftDeletesRemoved() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)

        let keep = Companion(displayName: "残る人", position: 0)
        let drop = Companion(displayName: "消える人", position: 1)
        let created = try await applications.create(
            draft(repIdentityID: identity.id, companions: [keep, drop])
        )
        XCTAssertEqual(created.companions.count, 2)

        var patch = ApplicationPatch()
        patch.companions = .set([keep])
        let updated = try await applications.update(id: created.id, patch)
        XCTAssertEqual(updated.companions.map(\.id), [keep.id])

        let context = ModelContext(container)
        let all = try ApplicationCompanionRecord.fetchAll(applicationID: created.id, in: context)
        XCTAssertEqual(all.count, 2)
        let dropped = all.first { $0.id == drop.id }
        XCTAssertNotNil(dropped?.deletedAt)
        XCTAssertEqual(dropped?.syncState, .pendingDelete)
    }

    func testDeleteSoftDeletesApplicationAndCompanions() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let created = try await applications.create(
            draft(repIdentityID: identity.id, companions: [Companion(displayName: "同行", position: 0)])
        )

        try await applications.delete(id: created.id)

        let page = try await applications.listPage(limit: 10, cursor: nil)
        XCTAssertTrue(page.items.isEmpty)

        let context = ModelContext(container)
        XCTAssertTrue(try ApplicationCompanionRecord.fetchActive(applicationID: created.id, in: context).isEmpty)
        let record = try ApplicationRecord.fetchRecord(id: created.id, in: context)
        XCTAssertEqual(record?.syncState, .pendingDelete)
    }

    func testCursorRoundTripAndRejectsBrokenCursor() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let cursor = SwiftDataApplicationRepository.formatCursor(updatedAt: date, id: id)
        let parsed = try SwiftDataApplicationRepository.parseCursor(cursor)
        XCTAssertEqual(parsed.id, id)
        XCTAssertEqual(parsed.updatedAt.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)

        XCTAssertThrowsError(try SwiftDataApplicationRepository.parseCursor("not-a-cursor"))
    }

    func testApplicationPayloadHasNoTourID() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let created = try await applications.create(draft(repIdentityID: identity.id))

        let context = ModelContext(container)
        let record = try XCTUnwrap(try ApplicationRecord.fetchRecord(id: created.id, in: context))
        let payload = record.syncPayload()
        // applications テーブルに tour_id は無い（event 経由 / sync-payload.mapper.ts）
        XCTAssertNil(payload["tour_id"])
        XCTAssertEqual(payload["event_id"], .string(created.eventID.uuidString))
        XCTAssertEqual(payload["status"], .string("applied"))
        XCTAssertEqual(payload["ticket_count"], .number(2))
        XCTAssertEqual(payload["rep_membership_id"], .null)
    }
}
