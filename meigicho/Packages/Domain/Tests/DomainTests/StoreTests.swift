import XCTest
@testable import Domain

/// T0 のストア分割が既存の集計ロジックを保っていることの確認。
/// （振る舞い不変が T0 の最重要要件）
@MainActor
final class StoreTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_785_000_000) // 2026-07-31 JST 前後
    private let identityA = UUID(uuidString: "00000000-0000-7000-8000-0000000000A1")!
    private let identityB = UUID(uuidString: "00000000-0000-7000-8000-0000000000B1")!
    private let tour1 = UUID(uuidString: "00000000-0000-7000-8000-000000000101")!
    private let tour2 = UUID(uuidString: "00000000-0000-7000-8000-000000000102")!
    private let event1 = UUID(uuidString: "00000000-0000-7000-8000-000000000201")!
    private let event2 = UUID(uuidString: "00000000-0000-7000-8000-000000000202")!
    private let event3 = UUID(uuidString: "00000000-0000-7000-8000-000000000203")!

    private func makeStore() -> ApplicationStore {
        let store = ApplicationStore(now: { [today] in today })
        store.tours = [
            Tour(id: tour1, name: "TOUR 1", artistNameRaw: "ARTIST 1", updatedAt: today),
            Tour(id: tour2, name: "TOUR 2", artistNameRaw: "ARTIST 2", updatedAt: today),
        ]
        store.events = [
            EventEntity(id: event1, tourID: tour1, name: "公演A", venueNameRaw: "会場A",
                        eventDate: day(2026, 9, 13), startsAt: nil, updatedAt: today),
            EventEntity(id: event2, tourID: tour1, name: "公演B", venueNameRaw: "会場B",
                        eventDate: day(2026, 8, 30), startsAt: nil, updatedAt: today),
            // event3 は意図的に登録しない（手元に無い公演）
        ]
        store.applications = [
            ApplicationEntry(id: UUID(), tourID: tour1, eventID: event1, repIdentityID: identityA,
                             status: .won, seatRaw: "アリーナ8列", updatedAt: today),
            ApplicationEntry(id: UUID(), tourID: tour1, eventID: event2, repIdentityID: identityB,
                             status: .applied,
                             companions: [Companion(id: UUID(), identityID: identityA, displayName: "A", position: 0)],
                             updatedAt: today),
            ApplicationEntry(id: UUID(), tourID: tour2, eventID: event3, repIdentityID: identityA,
                             status: .applied, updatedAt: today),
        ]
        return store
    }

    // AC-AP-01-T の前提: 対応する event が無ければ nil。空文字を作らない
    func testEventLookupReturnsNilWhenEventIsMissing() {
        let store = makeStore()
        let orphan = store.applications[2]
        XCTAssertNil(store.eventName(for: orphan))
        XCTAssertNil(store.venueName(for: orphan))
        XCTAssertNil(store.eventDate(for: orphan))
        XCTAssertEqual(store.artistName(for: orphan), "ARTIST 2") // tour は手元にある
    }

    func testEventLookupResolvesNames() {
        let store = makeStore()
        let app = store.applications[0]
        XCTAssertEqual(store.eventName(for: app), "公演A")
        XCTAssertEqual(store.venueName(for: app), "会場A")
        XCTAssertEqual(store.tourName(for: app), "TOUR 1")
        XCTAssertEqual(store.artistName(for: app), "ARTIST 1")
    }

    // E-8: event_date が nil の申込は公演日ソートで末尾
    func testApplicationsWithoutEventDateSortLast() {
        let store = makeStore()
        let sorted = store.filteredApplications(filter: .all, search: "")
        XCTAssertEqual(sorted.count, 3)
        XCTAssertNil(store.eventDate(for: sorted.last!))
        XCTAssertEqual(store.eventDate(for: sorted[0]), day(2026, 8, 30))
    }

    func testGroupingUsesTourIDNotTourName() {
        let store = makeStore()
        let groups = store.allTourGroups()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.id)), [tour1, tour2])
        let first = groups.first { $0.id == tour1 }
        XCTAssertEqual(first?.items.count, 2)
        XCTAssertEqual(first?.tour.name, "TOUR 1")
    }

    func testSearchMatchesEventVenueAndArtistWithoutCrashingOnMissingEvent() {
        let store = makeStore()
        XCTAssertEqual(store.filteredApplications(filter: .all, search: "会場A").count, 1)
        XCTAssertEqual(store.filteredApplications(filter: .all, search: "ARTIST 2").count, 1)
        XCTAssertEqual(store.filteredApplications(filter: .all, search: "存在しない").count, 0)
    }

    func testWinCountsCountRepresentativeOnly() {
        let store = makeStore()
        XCTAssertEqual(store.winCount(for: identityA), 1)
        XCTAssertEqual(store.winCount(for: identityB), 0)
        // 同行者としての参加も申込一覧には含まれる
        XCTAssertEqual(store.applications(for: identityA).count, 3)
        XCTAssertEqual(store.applications(for: identityB).count, 1)
        XCTAssertEqual(store.winCounts()[identityA], 1)
    }

    func testPendingResultCountAndAwaitingResults() {
        let store = makeStore()
        XCTAssertEqual(store.pendingResultCount(), 2)
        XCTAssertEqual(store.awaitingResults(limit: 1).count, 1)
    }

    func testUpcomingWonEventsSkipsApplicationsWithoutEventDate() {
        let store = makeStore()
        let upcoming = store.upcomingWonEvents()
        XCTAssertEqual(upcoming.count, 1)
        XCTAssertEqual(store.eventName(for: upcoming[0]), "公演A")
    }

    func testAddApplicationReusesExistingTourWithSameName() async throws {
        let store = makeStore()
        let draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR 1", artistNameRaw: "ARTIST 1"),
            event: EventDraft(name: "公演C", venueNameRaw: "会場C", eventDate: day(2026, 10, 1)),
            repIdentityID: identityA
        )
        // repository 未注入（Preview 相当）はローカルだけで完結する
        let result = await store.addApplication(draft)
        let created = try XCTUnwrap(result)
        XCTAssertEqual(store.tours.count, 2, "同名ツアーは作り直さない")
        XCTAssertEqual(created.tourID, tour1)
        XCTAssertEqual(store.events.count, 3)
        XCTAssertEqual(store.eventName(for: created), "公演C")
    }

    func testAddApplicationCreatesNewTourWhenNameIsNew() async {
        let store = makeStore()
        let draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR 3", artistNameRaw: ""),
            event: EventDraft(name: "公演D", venueNameRaw: "", eventDate: nil),
            repIdentityID: identityA
        )
        _ = await store.addApplication(draft)
        XCTAssertEqual(store.tours.count, 3)
    }

    func testIdentityStoreAggregatesMembershipsByIdentity() {
        let store = IdentityStore(now: { [today] in today })
        store.identities = [
            Identity(id: identityA, displayName: "A", relation: .self, colorHex: "#000000", updatedAt: today),
            Identity(id: identityB, displayName: "B", relation: .friend, colorHex: "#111111", updatedAt: today),
        ]
        store.memberships = [
            Membership(id: UUID(), identityID: identityA, fanClubNameRaw: "FC1", renewalOn: today.addingTimeInterval(10 * 86_400)),
            Membership(id: UUID(), identityID: identityA, fanClubNameRaw: "FC2", renewalOn: today.addingTimeInterval(90 * 86_400)),
            Membership(id: UUID(), identityID: identityB, fanClubNameRaw: "FC3", renewalOn: nil),
        ]
        XCTAssertEqual(store.memberships(for: identityA).count, 2)
        XCTAssertEqual(store.expiringMembershipCount(), 1)

        let sorted = store.sortedIdentities(by: .renewalSoon, winCounts: [:])
        XCTAssertEqual(sorted.first?.id, identityA)

        let byWins = store.sortedIdentities(by: .mostWins, winCounts: [identityB: 5, identityA: 1])
        XCTAssertEqual(byWins.first?.id, identityB)
    }

    // ゲスト（未ログイン）閲覧モード（Q5）: ログアウト後もタブは見えたままなので、
    // 前のユーザーのデータが残っていると他人の端末に見えてしまう
    func testApplicationStoreClearRemovesEverything() {
        let store = makeStore()
        store.applicationsState = .loaded
        store.catalogState = .loaded
        store.truncated = true
        store.writeError = .offline

        store.clear()

        XCTAssertTrue(store.applications.isEmpty)
        XCTAssertTrue(store.tours.isEmpty)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertEqual(store.applicationsState, .idle)
        XCTAssertEqual(store.catalogState, .idle)
        XCTAssertFalse(store.truncated)
        XCTAssertNil(store.writeError)
    }

    func testIdentityStoreClearRemovesEverything() {
        let store = IdentityStore(now: { [today] in today })
        store.identities = [Identity(id: identityA, displayName: "A", relation: .self, colorHex: "#111111")]
        store.memberships = [Membership(id: UUID(), identityID: identityA, fanClubNameRaw: "FC1", renewalOn: nil)]
        store.identitiesState = .loaded
        store.membershipsState = .loaded
        store.actionError = .offline

        store.clear()

        XCTAssertTrue(store.identities.isEmpty)
        XCTAssertTrue(store.memberships.isEmpty)
        XCTAssertEqual(store.identitiesState, .idle)
        XCTAssertEqual(store.membershipsState, .idle)
        XCTAssertNil(store.actionError)
    }

    func testNewIdentityDefaultsToHistoryHidden() {
        // Q9 / docs/03 §4.4: 共有はオプトイン
        let identity = Identity(displayName: "新規", relation: .other, colorHex: "#000000")
        XCTAssertFalse(identity.historyVisible)
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
