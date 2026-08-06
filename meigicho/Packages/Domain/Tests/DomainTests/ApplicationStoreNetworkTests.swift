import XCTest
@testable import Domain

/// T3（申込 + ツアー/公演）の `plan.md` §4.4 AC-AP-01〜05 / 12。
/// ネットワークは `ApplicationRepository` / `CatalogRepository` のフェイクで代替する。
@MainActor
final class ApplicationStoreNetworkTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_785_000_000)
    private let identityA = UUID(uuidString: "00000000-0000-7000-8000-0000000000A1")!
    private let identityB = UUID(uuidString: "00000000-0000-7000-8000-0000000000B1")!
    private let tour1 = UUID(uuidString: "00000000-0000-7000-8000-000000000101")!
    private let event1 = UUID(uuidString: "00000000-0000-7000-8000-000000000201")!
    private let event2 = UUID(uuidString: "00000000-0000-7000-8000-000000000202")!

    // MARK: - AC-AP-05-T: ページング

    func testPagingStopsWhenHasMoreIsFalse() async {
        let repository = FakeApplicationRepository(pages: [
            makePage(count: 2, nextCursor: "c1", hasMore: true),
            makePage(count: 1, nextCursor: nil, hasMore: false),
        ])
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        await store.loadApplications()

        XCTAssertEqual(store.applications.count, 3)
        XCTAssertFalse(store.truncated)
        XCTAssertEqual(store.applicationsState, .loaded)
        let calls = await repository.calls
        XCTAssertEqual(calls.count, 2)
        // cursor は opaque。返ってきた値をそのまま次に渡す（解釈も生成もしない）
        XCTAssertEqual(calls.map(\.cursor), [nil, "c1"])
        XCTAssertEqual(calls.map(\.limit), [ApplicationStore.pageLimit, ApplicationStore.pageLimit])
    }

    func testPagingStopsWhenNextCursorIsMissingEvenIfHasMoreIsTrue() async {
        // has_more は true だが next_cursor が無い（無限ループさせない）
        let repository = FakeApplicationRepository(pages: [
            makePage(count: 1, nextCursor: nil, hasMore: true)
        ])
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        await store.loadApplications()

        let calls = await repository.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(store.truncated)
    }

    func testPagingTruncatesAfterMaxPages() async {
        // 常に has_more == true を返す repository
        let repository = FakeApplicationRepository(alwaysMore: true, itemsPerPage: 1)
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        await store.loadApplications()

        let calls = await repository.calls
        XCTAssertEqual(calls.count, ApplicationStore.maxPages)
        XCTAssertTrue(store.truncated)
        XCTAssertEqual(store.applications.count, ApplicationStore.maxPages)
    }

    func testLoadFailureKeepsAlreadyLoadedApplications() async {
        // AC-AP-11-M の機械化: 失敗しても既読データを消さない
        let repository = FakeApplicationRepository(pages: [makePage(count: 2, nextCursor: nil, hasMore: false)])
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        await store.loadApplications()
        XCTAssertEqual(store.applications.count, 2)

        await repository.setFailure(.offline)
        await store.loadApplications()

        XCTAssertEqual(store.applications.count, 2, "読み込み失敗で一覧を空にしない")
        XCTAssertEqual(store.applicationsState.error, .offline)
    }

    // MARK: - AC-AP-01-T: join

    func testDisplayResolvesNamesAndReturnsNilForMissingEvent() {
        let store = ApplicationStore(now: { [today] in today })
        store.tours = [Tour(id: tour1, name: "TOUR 1", artistNameRaw: "ARTIST 1", updatedAt: today)]
        store.events = [
            EventEntity(id: event1, tourID: tour1, name: "公演A", venueNameRaw: "会場A",
                        eventDate: day(2026, 9, 13), updatedAt: today)
        ]
        store.applications = [
            entry(id: UUID(), eventID: event1),
            entry(id: UUID(), eventID: event2),   // 手元に無い公演
        ]

        let resolved = store.display(for: store.applications[0])
        XCTAssertEqual(resolved.eventName, "公演A")
        XCTAssertEqual(resolved.venueName, "会場A")
        XCTAssertEqual(resolved.tourName, "TOUR 1")

        let missing = store.display(for: store.applications[1])
        XCTAssertNil(missing.eventName, "空文字を作らない")
        XCTAssertNil(missing.venueName)
        XCTAssertNil(missing.eventDate)
    }

    /// 手元に無い公演は `GET /v1/events/:id` を単発で引いて埋める（contract-mapping §4.6）
    func testMissingEventIsFetchedOnceAfterLoad() async {
        let fetched = EventEntity(id: event2, tourID: tour1, name: "公演B", venueNameRaw: "会場B",
                                  eventDate: day(2026, 10, 1), updatedAt: today)
        let catalog = FakeCatalogRepository(tours: [], events: [], fetchable: [event2: fetched])
        let repository = FakeApplicationRepository(pages: [
            ApplicationPage(items: [entry(id: UUID(), eventID: event2), entry(id: UUID(), eventID: event2)],
                            nextCursor: nil, hasMore: false)
        ])
        let store = ApplicationStore(repository: repository, catalogRepository: catalog, now: { [today] in today })
        await store.loadApplications()

        XCTAssertEqual(store.event(for: event2)?.name, "公演B")
        let count = await catalog.fetchEventCount
        XCTAssertEqual(count, 1, "同じ event を 2 回引かない")
    }

    // MARK: - AC-AP-04-T: event_date が nil のソート

    func testApplicationsWithoutEventDateSortLast() {
        let store = ApplicationStore(now: { [today] in today })
        store.tours = [Tour(id: tour1, name: "TOUR 1", updatedAt: today)]
        store.events = [
            EventEntity(id: event1, tourID: tour1, name: "公演A", eventDate: day(2026, 9, 13), updatedAt: today),
            EventEntity(id: event2, tourID: tour1, name: "公演B", eventDate: nil, updatedAt: today),
        ]
        let withDate = entry(id: UUID(), eventID: event1)
        let withoutDate = entry(id: UUID(), eventID: event2)
        store.applications = [withoutDate, withDate]

        let sorted = store.filteredApplications(filter: .all, search: "")
        XCTAssertEqual(sorted.map(\.id), [withDate.id, withoutDate.id])
    }

    // MARK: - AC-AP-02-T / AC-AP-03-T: companions の正規化

    func testNormalizedCompanionsRenumbersPositionsFromZero() {
        let companions = [
            Companion(id: UUID(), identityID: identityA, displayName: "A", position: 5),
            Companion(id: UUID(), identityID: nil, displayName: "外部", position: 9),
        ]
        let normalized = ApplicationStore.normalizedCompanions(companions)
        XCTAssertEqual(normalized.map(\.position), [0, 1])
        XCTAssertEqual(normalized.map(\.displayName), ["A", "外部"])
        // id は保持する（PATCH の全置換で必要）
        XCTAssertEqual(normalized.map(\.id), companions.map(\.id))
    }

    func testNormalizedCompanionsRemovesDuplicatedIdentityIDs() {
        let companions = [
            Companion(id: UUID(), identityID: identityA, displayName: "A", position: 0),
            Companion(id: UUID(), identityID: identityA, displayName: "Aの重複", position: 1),
            Companion(id: UUID(), identityID: identityB, displayName: "B", position: 2),
            // identity_id が nil の同行者は重複扱いしない
            Companion(id: UUID(), identityID: nil, displayName: "外部1", position: 3),
        ]
        let normalized = ApplicationStore.normalizedCompanions(companions)
        XCTAssertEqual(normalized.count, 3)
        XCTAssertEqual(normalized.map(\.displayName), ["A", "B", "外部1"])
        XCTAssertEqual(normalized.map(\.position), [0, 1, 2])
    }

    func testNormalizedCompanionsCapsAtThree() {
        let companions = (0..<5).map {
            Companion(id: UUID(), identityID: nil, displayName: "同行者\($0)", position: $0)
        }
        XCTAssertEqual(ApplicationStore.normalizedCompanions(companions).count, ApplicationStore.maxCompanions)
    }

    // MARK: - AC-AP-12: rep_membership_id は常に nil

    func testNormalizedDraftAlwaysClearsRepMembershipID() {
        var draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR"),
            event: EventDraft(name: "公演"),
            repIdentityID: identityA
        )
        draft.repMembershipID = UUID()
        XCTAssertNil(ApplicationStore.normalizedDraft(draft).repMembershipID)
    }

    // MARK: - AC-AP-07-M の機械化: find-or-create の結果でカタログを揃える

    func testCreateUsesServerTourIDWithoutDuplicatingExistingTour() async {
        let serverTourID = tour1
        let repository = FakeApplicationRepository(pages: [])
        // サーバーは同名ツアーを見つけて既存の tour_id を返す
        await repository.setCreateResult { draft in
            ApplicationEntry(id: draft.id, tourID: serverTourID, eventID: draft.event.id,
                             repIdentityID: draft.repIdentityID, status: draft.status)
        }
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        store.tours = [Tour(id: serverTourID, name: "TOUR 1", artistNameRaw: "ARTIST 1", updatedAt: today)]

        let draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR 1", artistNameRaw: "ARTIST 1"),
            event: EventDraft(name: "公演C", venueNameRaw: "会場C", eventDate: day(2026, 10, 1)),
            repIdentityID: identityA
        )
        let created = await store.addApplication(draft)

        XCTAssertEqual(created?.tourID, serverTourID)
        XCTAssertEqual(store.tours.count, 1, "既存ツアーに吸収されたらツアーは増えない")
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(store.eventName(for: created!), "公演C")
        XCTAssertNil(store.writeError)
    }

    func testCreateFailureKeepsFormDataAndReportsError() async {
        let repository = FakeApplicationRepository(pages: [])
        await repository.setFailure(.offline)
        let store = ApplicationStore(repository: repository, now: { [today] in today })

        let created = await store.addApplication(
            ApplicationDraft(tour: TourDraft(name: "T"), event: EventDraft(name: "E"), repIdentityID: identityA)
        )
        XCTAssertNil(created)
        XCTAssertEqual(store.writeError, .offline)
        XCTAssertTrue(store.applications.isEmpty, "失敗した申込を一覧に残さない")
        XCTAssertTrue(store.tours.isEmpty)
    }

    // MARK: - 座席・ステータスの PATCH

    func testStatusChangeSendsOnlyStatusAndKeepsSeat() async {
        let existing = entry(id: UUID(), eventID: event1, status: .won, seatRaw: "アリーナ8列")
        let repository = FakeApplicationRepository(pages: [])
        await repository.setUpdateResult { id, patch in
            var updated = existing
            updated.status = patch.status.applied(to: updated.status) ?? updated.status
            updated.seatRaw = patch.seatRaw.applied(to: updated.seatRaw) ?? updated.seatRaw
            return updated
        }
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        store.applications = [existing]

        await store.updateApplicationStatus(existing.id, status: .lost)

        let patches = await repository.updatePatches
        XCTAssertEqual(patches.count, 1)
        XCTAssertTrue(patches[0].seatRaw.isUnchanged, "座席のキーを送らない（消さない）")
        XCTAssertEqual(patches[0].status, .set(.lost))
        XCTAssertEqual(store.applications[0].seatRaw, "アリーナ8列")
        XCTAssertEqual(store.applications[0].status, .lost)
    }

    func testSeatEditSendsNullWhenCleared() async {
        let existing = entry(id: UUID(), eventID: event1, status: .won, seatRaw: "アリーナ8列")
        let repository = FakeApplicationRepository(pages: [])
        await repository.setUpdateResult { _, _ in
            var updated = existing
            updated.seatRaw = ""
            return updated
        }
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        store.applications = [existing]

        await store.updateApplicationSeat(existing.id, seat: "   ")

        let patches = await repository.updatePatches
        XCTAssertEqual(patches[0].seatRaw, .set(nil), "空文字は null を送ってクリアする")
    }

    func testUpdateFailureRollsBackOptimisticValue() async {
        let existing = entry(id: UUID(), eventID: event1, status: .applied, seatRaw: "")
        let repository = FakeApplicationRepository(pages: [])
        await repository.setFailure(.offline)
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        store.applications = [existing]

        await store.updateApplicationStatus(existing.id, status: .won)

        XCTAssertEqual(store.applications[0].status, .applied, "失敗したら UI の値が巻き戻る")
        XCTAssertEqual(store.writeError, .offline)
    }

    // MARK: - ヘルパー

    private func makePage(count: Int, nextCursor: String?, hasMore: Bool) -> ApplicationPage {
        ApplicationPage(
            items: (0..<count).map { _ in entry(id: UUID(), eventID: event1) },
            nextCursor: nextCursor,
            hasMore: hasMore
        )
    }

    private func entry(
        id: UUID,
        eventID: UUID,
        status: ApplicationStatus = .applied,
        seatRaw: String = ""
    ) -> ApplicationEntry {
        ApplicationEntry(id: id, tourID: tour1, eventID: eventID, repIdentityID: identityA,
                         status: status, seatRaw: seatRaw, updatedAt: today)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }
}

// MARK: - フェイク

actor FakeApplicationRepository: ApplicationRepository {
    struct Call: Sendable {
        let limit: Int
        let cursor: String?
    }

    private(set) var calls: [Call] = []
    private(set) var updatePatches: [ApplicationPatch] = []
    private var pages: [ApplicationPage]
    private let alwaysMore: Bool
    private let itemsPerPage: Int
    private var failure: AppError?
    private var createResult: (@Sendable (ApplicationDraft) -> ApplicationEntry)?
    private var updateResult: (@Sendable (UUID, ApplicationPatch) -> ApplicationEntry)?

    init(pages: [ApplicationPage] = [], alwaysMore: Bool = false, itemsPerPage: Int = 1) {
        self.pages = pages
        self.alwaysMore = alwaysMore
        self.itemsPerPage = itemsPerPage
    }

    func setFailure(_ error: AppError?) { failure = error }
    func setCreateResult(_ handler: @escaping @Sendable (ApplicationDraft) -> ApplicationEntry) {
        createResult = handler
    }
    func setUpdateResult(_ handler: @escaping @Sendable (UUID, ApplicationPatch) -> ApplicationEntry) {
        updateResult = handler
    }

    func listPage(limit: Int, cursor: String?) async throws -> ApplicationPage {
        calls.append(Call(limit: limit, cursor: cursor))
        if let failure { throw failure }
        if alwaysMore {
            let items = (0..<itemsPerPage).map { _ in
                ApplicationEntry(id: UUID(), tourID: UUID(), eventID: UUID(), repIdentityID: UUID())
            }
            return ApplicationPage(items: items, nextCursor: "cursor-\(calls.count)", hasMore: true)
        }
        guard calls.count <= pages.count else {
            return ApplicationPage(items: [], nextCursor: nil, hasMore: false)
        }
        return pages[calls.count - 1]
    }

    func create(_ draft: ApplicationDraft) async throws -> ApplicationEntry {
        if let failure { throw failure }
        if let createResult { return createResult(draft) }
        return ApplicationEntry(id: draft.id, tourID: draft.tour.id, eventID: draft.event.id,
                                repIdentityID: draft.repIdentityID, status: draft.status)
    }

    func update(id: UUID, _ patch: ApplicationPatch) async throws -> ApplicationEntry {
        updatePatches.append(patch)
        if let failure { throw failure }
        if let updateResult { return updateResult(id, patch) }
        throw AppError.notFound
    }

    func delete(id: UUID) async throws {
        if let failure { throw failure }
    }
}

actor FakeCatalogRepository: CatalogRepository {
    private let tours: [Tour]
    private let events: [EventEntity]
    private let fetchable: [UUID: EventEntity]
    private(set) var fetchEventCount = 0

    init(tours: [Tour], events: [EventEntity], fetchable: [UUID: EventEntity] = [:]) {
        self.tours = tours
        self.events = events
        self.fetchable = fetchable
    }

    func listTours() async throws -> [Tour] { tours }
    func listEvents() async throws -> [EventEntity] { events }

    func fetchEvent(id: UUID) async throws -> EventEntity {
        fetchEventCount += 1
        guard let event = fetchable[id] else { throw AppError.notFound }
        return event
    }

    func updateTour(id: UUID, _ patch: TourPatch) async throws -> Tour { throw AppError.notFound }
    func updateEvent(id: UUID, _ patch: EventPatch) async throws -> EventEntity { throw AppError.notFound }
}
