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

    /// 【回帰・NFR-1】申込追加で既存の同名ツアーに吸収されても、フォームのアーティスト名で
    /// 既存ツアーの `artistNameRaw` が書き換わらない（`findOrCreateTour` は create/updateScoped 両方から
    /// 呼ばれる共有ロジックなので、編集経路向けの修正が追加フローの既存挙動を変えていないことを検証する）。
    func testCreateDoesNotOverwriteExistingTourArtistNameOnAbsorption() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let first = try await applications.create(draft(repIdentityID: identity.id, tourName: "共有ツアー"))
        let second = try await applications.create(
            ApplicationDraft(
                tour: TourDraft(name: "共有ツアー", artistNameRaw: "別アーティスト"),
                event: EventDraft(name: "別公演", venueNameRaw: "別会場", eventDate: Date(timeIntervalSince1970: 1_800_100_000)),
                repIdentityID: identity.id,
                status: .applied,
                ticketCount: 1
            )
        )
        XCTAssertEqual(first.tourID, second.tourID, "同名ツアーは1件に寄る")

        let tours = try await catalog.listTours()
        let tour = try XCTUnwrap(tours.first { $0.id == first.tourID })
        XCTAssertEqual(tour.artistNameRaw, "ARTIST", "先に作られたツアーのアーティスト名を保持する")
    }

    /// 【回帰】ソフトデリート済みツアーと同名で申込を追加すると、ツアーが復活し
    /// 新しいアーティスト名が反映される（BE `tours.service.ts` の復活時挙動と同じ、従来からの挙動）。
    /// `findOrCreateTour` の「吸収時は artistNameRaw を上書きしない」修正（`existing.id == draft.id` ガード）が
    /// 復活分岐まで巻き込んでいないことを検証する（create 経路の `draft.id` は常に新規 UUID のため）。
    func testCreateRevivesSoftDeletedTourAndUpdatesArtistName() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let first = try await applications.create(
            ApplicationDraft(
                tour: TourDraft(name: "復活ツアー", artistNameRaw: "OLD"),
                event: EventDraft(name: "初回公演", venueNameRaw: "会場A", eventDate: Date(timeIntervalSince1970: 1_800_000_000)),
                repIdentityID: identity.id,
                status: .applied,
                ticketCount: 1
            )
        )
        try await applications.delete(id: first.id)

        let context = ModelContext(container)
        let tourID = first.tourID
        let tourRecord = try XCTUnwrap(
            try context.fetch(FetchDescriptor<TourRecord>(predicate: #Predicate { $0.id == tourID })).first
        )
        tourRecord.softDelete()
        try context.save()

        let second = try await applications.create(
            ApplicationDraft(
                tour: TourDraft(name: "復活ツアー", artistNameRaw: "NEW"),
                event: EventDraft(name: "2回目公演", venueNameRaw: "会場B", eventDate: Date(timeIntervalSince1970: 1_800_100_000)),
                repIdentityID: identity.id,
                status: .applied,
                ticketCount: 1
            )
        )

        XCTAssertEqual(second.tourID, first.tourID, "同名のソフトデリート済みツアーを復活させる")
        let toursAfterRevival = try await catalog.listTours()
        let revivedTour = try XCTUnwrap(toursAfterRevival.first { $0.id == first.tourID })
        XCTAssertEqual(revivedTour.artistNameRaw, "NEW", "復活時は新しいアーティスト名を反映する")
    }

    /// 【回帰】同一ツアーの現地更新（ツアー名は変えずアーティスト名だけ変更）でアーティスト名を
    /// 空欄にすると、空への変更も反映される（FR-AE-8）。吸収防止の `existing.id == draft.id` ガードが
    /// 「空文字は無視」という別の黙殺と結合して、クリアそのものを黙殺しないことを検証する。
    func testUpdateScopedClearsArtistNameOnSameTour() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let target = try await applications.create(draft(repIdentityID: identity.id, tourName: "ツアーA"))
        let toursBefore = try await catalog.listTours()
        let currentTour = try XCTUnwrap(toursBefore.first { $0.id == target.tourID })
        XCTAssertEqual(currentTour.artistNameRaw, "ARTIST")
        let currentEvent = try await catalog.fetchEvent(id: target.eventID)

        let plan = ApplicationEditPlanner.makePlan(
            current: target,
            currentTour: currentTour,
            currentEvent: currentEvent,
            input: ApplicationEditFormInput(
                eventName: currentEvent.name,
                tourName: currentTour.name,
                artistNameRaw: "",
                venueNameRaw: currentEvent.venueNameRaw,
                eventDate: currentEvent.eventDate,
                repIdentityID: target.repIdentityID,
                status: target.status
            )
        )

        _ = try await applications.updateScoped(applicationID: target.id, plan: plan)

        let toursAfter = try await catalog.listTours()
        let updatedTour = try XCTUnwrap(toursAfter.first { $0.id == target.tourID })
        XCTAssertEqual(updatedTour.artistNameRaw, "", "同一ツアーの現地更新では空へのクリアも反映する")
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

    // MARK: - updateScoped (T3・`docs/plans/application-edit/plan.md`)

    /// AC-AE-09: ツアー名を既存の別ツアー名に変更すると、ツアーが新規に増えず
    /// 対象公演の `tourID` が既存ツアーを指すようになる。
    func testUpdateScopedRetargetsEventToExistingTourByName() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        // 既存の別ツアー（付け替え先）
        let otherTourApplication = try await applications.create(
            draft(repIdentityID: identity.id, tourName: "既存ツアーB")
        )
        // 編集対象
        let target = try await applications.create(
            draft(repIdentityID: identity.id, tourName: "ツアーA")
        )
        let toursBefore = try await catalog.listTours()
        XCTAssertEqual(toursBefore.count, 2)

        let currentTour = try XCTUnwrap(toursBefore.first { $0.id == target.tourID })
        let currentEvent = try await catalog.fetchEvent(id: target.eventID)

        let plan = ApplicationEditPlanner.makePlan(
            current: target,
            currentTour: currentTour,
            currentEvent: currentEvent,
            input: ApplicationEditFormInput(
                eventName: currentEvent.name,
                tourName: "既存ツアーB",
                artistNameRaw: currentTour.artistNameRaw,
                venueNameRaw: currentEvent.venueNameRaw,
                eventDate: currentEvent.eventDate,
                repIdentityID: target.repIdentityID,
                status: target.status
            )
        )

        let updated = try await applications.updateScoped(applicationID: target.id, plan: plan)

        let toursAfter = try await catalog.listTours()
        XCTAssertEqual(toursAfter.count, 2, "ツアーは新規に増えない")
        XCTAssertEqual(updated.tourID, otherTourApplication.tourID)

        let event = try await catalog.fetchEvent(id: target.eventID)
        XCTAssertEqual(event.tourID, otherTourApplication.tourID)
    }

    /// 【回帰】ツアー名を既存の別ツアー名に変更して吸収されたとき、吸収先の既存ツアーの
    /// `artistNameRaw` は編集前ツアーの文脈から来た値で上書きされない（FR-AE-9）。
    /// `testUpdateScopedRetargetsEventToExistingTourByName` はアーティスト名が両ツアーで同じため
    /// この上書きバグを検出できない。ここでは意図的に異なるアーティスト名を使う。
    func testUpdateScopedAbsorptionDoesNotOverwriteExistingTourArtistName() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let absorbed = try await applications.create(
            ApplicationDraft(
                tour: TourDraft(name: "既存ツアーB", artistNameRaw: "LUMINA"),
                event: EventDraft(name: "大阪公演", venueNameRaw: "京セラドーム", eventDate: Date(timeIntervalSince1970: 1_800_000_000)),
                repIdentityID: identity.id,
                status: .applied,
                ticketCount: 2
            )
        )
        let target = try await applications.create(draft(repIdentityID: identity.id, tourName: "ツアーA"))

        let toursBefore = try await catalog.listTours()
        let currentTour = try XCTUnwrap(toursBefore.first { $0.id == target.tourID })
        let currentEvent = try await catalog.fetchEvent(id: target.eventID)

        let plan = ApplicationEditPlanner.makePlan(
            current: target,
            currentTour: currentTour,
            currentEvent: currentEvent,
            input: ApplicationEditFormInput(
                eventName: currentEvent.name,
                tourName: "既存ツアーB",
                artistNameRaw: currentTour.artistNameRaw,
                venueNameRaw: currentEvent.venueNameRaw,
                eventDate: currentEvent.eventDate,
                repIdentityID: target.repIdentityID,
                status: target.status
            )
        )

        _ = try await applications.updateScoped(applicationID: target.id, plan: plan)

        let toursAfterAbsorb = try await catalog.listTours()
        let absorbedTour = try XCTUnwrap(toursAfterAbsorb.first { $0.id == absorbed.tourID })
        XCTAssertEqual(absorbedTour.artistNameRaw, "LUMINA", "吸収先の既存アーティスト名を保持する")
    }

    /// AC-AE-10: 未使用のツアー名を含む `TourDraft` を渡すと、ツアーが1件だけ新規に増え、
    /// 他の申込が参照しているツアーは変わらない。
    func testUpdateScopedCreatesNewTourForUnusedName() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)
        let catalog = SwiftDataCatalogRepository(container: container)

        let other = try await applications.create(draft(repIdentityID: identity.id, tourName: "ツアーA"))
        let target = try await applications.create(draft(repIdentityID: identity.id, tourName: "ツアーA"))
        XCTAssertEqual(other.tourID, target.tourID)

        let toursBefore = try await catalog.listTours()
        XCTAssertEqual(toursBefore.count, 1)
        let currentTour = try XCTUnwrap(toursBefore.first)
        let currentEvent = try await catalog.fetchEvent(id: target.eventID)

        let plan = ApplicationEditPlanner.makePlan(
            current: target,
            currentTour: currentTour,
            currentEvent: currentEvent,
            input: ApplicationEditFormInput(
                eventName: currentEvent.name,
                tourName: "未使用ツアー名",
                artistNameRaw: currentTour.artistNameRaw,
                venueNameRaw: currentEvent.venueNameRaw,
                eventDate: currentEvent.eventDate,
                repIdentityID: target.repIdentityID,
                status: target.status
            )
        )

        let updated = try await applications.updateScoped(applicationID: target.id, plan: plan)

        let toursAfter = try await catalog.listTours()
        XCTAssertEqual(toursAfter.count, 2, "ツアーが1件だけ新規に増える")
        XCTAssertNotEqual(updated.tourID, currentTour.id)

        // 他の申込が参照しているツアーは変わらない
        let unaffected = try await catalog.fetchEvent(id: other.eventID)
        XCTAssertEqual(unaffected.tourID, currentTour.id)
    }

    /// AC-AE-02: 同行者を追加する `ApplicationPatch` を渡すと `fetchActive` が1件増え、
    /// outbox に `applicationCompanions` が積まれる。
    func testUpdateScopedAddsCompanionAndEnqueuesOutbox() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)

        let created = try await applications.create(draft(repIdentityID: identity.id))
        XCTAssertTrue(created.companions.isEmpty)

        var patch = ApplicationPatch()
        let newCompanion = Companion(displayName: "新しい同行者", position: 0)
        patch.companions = .set([newCompanion])
        let plan = ApplicationEditPlan(applicationPatch: patch, tourDraft: nil, eventDraft: nil)

        let updated = try await applications.updateScoped(applicationID: created.id, plan: plan)
        XCTAssertEqual(updated.companions.count, 1)

        let context = ModelContext(container)
        let active = try ApplicationCompanionRecord.fetchActive(applicationID: created.id, in: context)
        XCTAssertEqual(active.count, 1)

        let outbox = try context.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertTrue(outbox.contains { $0.targetID == newCompanion.id && $0.collection == .applicationCompanions })
    }

    /// AC-AE-13: 論理削除済みの申込 ID に対して `updateScoped` を呼ぶと `.notFound` を throw し、
    /// 新しい行が作られない。
    func testUpdateScopedThrowsNotFoundForDeletedApplication() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let applications = SwiftDataApplicationRepository(container: container)

        let created = try await applications.create(draft(repIdentityID: identity.id))
        try await applications.delete(id: created.id)

        var patch = ApplicationPatch()
        patch.note = .set("更新後メモ")
        let plan = ApplicationEditPlan(applicationPatch: patch, tourDraft: nil, eventDraft: nil)

        do {
            _ = try await applications.updateScoped(applicationID: created.id, plan: plan)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }

        let context = ModelContext(container)
        let all = try context.fetch(FetchDescriptor<ApplicationRecord>())
        XCTAssertEqual(all.count, 1, "新しい行が作られない")
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
