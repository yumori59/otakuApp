import XCTest
@testable import Domain

/// #21 当選/未入金・#22 立場（代表者/同行者）の純粋ロジック。
@MainActor
final class ApplicationStatusRoleTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_785_000_000)
    private let identityA = UUID(uuidString: "00000000-0000-7000-8000-0000000000A1")!
    private let identityB = UUID(uuidString: "00000000-0000-7000-8000-0000000000B1")!
    private let tour1 = UUID(uuidString: "00000000-0000-7000-8000-000000000101")!
    private let event1 = UUID(uuidString: "00000000-0000-7000-8000-000000000201")!
    private let event2 = UUID(uuidString: "00000000-0000-7000-8000-000000000202")!

    // MARK: - #21 ステータス

    func testWonUnpaidRawValueAndLabelMatchContract() {
        XCTAssertEqual(ApplicationStatus.wonUnpaid.rawValue, "won_unpaid")
        XCTAssertEqual(ApplicationStatus.wonUnpaid.label, "当選/未入金")
        XCTAssertEqual(ApplicationStatus.wonUnpaid.shortLabel, "未入金")
    }

    func testWonUnpaidIsWonButDistinctFromWonStamp() {
        XCTAssertEqual(ApplicationStatus.wonUnpaid.stampStatus, .wonUnpaid)
        XCTAssertNotEqual(ApplicationStatus.wonUnpaid.stampStatus, ApplicationStatus.won.stampStatus)
        XCTAssertTrue(ApplicationStatus.wonUnpaid.isWon)
        XCTAssertTrue(ApplicationStatus.won.isWon)
        for status in [ApplicationStatus.draft, .applied, .lost, .cancelled] {
            XCTAssertFalse(status.isWon, "\(status)")
        }
    }

    func testTapCycleOrderIncludesWonUnpaidAndSkipsCancelled() {
        XCTAssertEqual(ApplicationStatus.draft.nextInTapCycle, .applied)
        XCTAssertEqual(ApplicationStatus.applied.nextInTapCycle, .wonUnpaid)
        XCTAssertEqual(ApplicationStatus.wonUnpaid.nextInTapCycle, .won)
        XCTAssertEqual(ApplicationStatus.won.nextInTapCycle, .lost)
        XCTAssertEqual(ApplicationStatus.lost.nextInTapCycle, .draft)
        // 巡回に入っていない値は申込中へ戻す（従来の挙動）
        XCTAssertEqual(ApplicationStatus.cancelled.nextInTapCycle, .applied)
    }

    func testFilterIncludesWonUnpaidBetweenAppliedAndWon() {
        let cases = ApplicationFilter.allCases
        XCTAssertEqual(cases.map(\.rawValue), ["すべて", "下書き", "申込中", "未入金", "当選", "落選"])
    }

    private func makeStore(_ apps: [ApplicationEntry]) -> ApplicationStore {
        let store = ApplicationStore(now: { [today] in today })
        store.tours = [Tour(id: tour1, name: "TOUR", artistNameRaw: "A", updatedAt: today)]
        store.events = [
            EventEntity(id: event1, tourID: tour1, name: "公演A", eventDate: Date(timeIntervalSince1970: 1_790_000_000), updatedAt: today),
            EventEntity(id: event2, tourID: tour1, name: "公演B", eventDate: Date(timeIntervalSince1970: 1_791_000_000), updatedAt: today),
        ]
        store.applications = apps
        return store
    }

    func testWinCountIncludesWonUnpaid() {
        let store = makeStore([
            ApplicationEntry(tourID: tour1, eventID: event1, repIdentityID: identityA, status: .won),
            ApplicationEntry(tourID: tour1, eventID: event2, repIdentityID: identityA, status: .wonUnpaid),
            ApplicationEntry(tourID: tour1, eventID: event2, repIdentityID: identityA, status: .applied),
        ])
        XCTAssertEqual(store.winCount(for: identityA), 2)
        XCTAssertEqual(store.winCounts()[identityA], 2)
    }

    func testWinCountsCreditsCompanionIdentityForWonUnpaid() {
        let store = makeStore([
            ApplicationEntry(
                tourID: tour1, eventID: event1, repIdentityID: identityA, status: .wonUnpaid,
                companions: [Companion(identityID: identityB, displayName: "B", position: 0)]
            ),
        ])
        XCTAssertEqual(store.winCounts()[identityB], 1)
    }

    func testPendingResultCountAndAwaitingResultsStayAppliedOnly() {
        let store = makeStore([
            ApplicationEntry(tourID: tour1, eventID: event1, repIdentityID: identityA, status: .wonUnpaid),
            ApplicationEntry(tourID: tour1, eventID: event2, repIdentityID: identityA, status: .applied),
        ])
        XCTAssertEqual(store.pendingResultCount(), 1)
        XCTAssertEqual(store.awaitingResults().count, 1)
    }

    func testUpcomingWonEventsIncludesWonUnpaid() {
        let store = makeStore([
            ApplicationEntry(tourID: tour1, eventID: event1, repIdentityID: identityA, status: .wonUnpaid),
            ApplicationEntry(tourID: tour1, eventID: event2, repIdentityID: identityA, status: .applied),
        ])
        XCTAssertEqual(store.upcomingWonEvents().count, 1)
    }

    func testFilteredApplicationsWonUnpaidIsExactMatch() {
        let store = makeStore([
            ApplicationEntry(tourID: tour1, eventID: event1, repIdentityID: identityA, status: .wonUnpaid),
            ApplicationEntry(tourID: tour1, eventID: event2, repIdentityID: identityA, status: .won),
        ])
        XCTAssertEqual(store.filteredApplications(filter: .wonUnpaid, search: "").map(\.status), [.wonUnpaid])
        XCTAssertEqual(store.filteredApplications(filter: .won, search: "").map(\.status), [.won])
    }

    // MARK: - #22 立場

    func testRoleLabels() {
        XCTAssertEqual(ApplicationRole.representative.label, "代表者")
        XCTAssertEqual(ApplicationRole.companion.label, "同行者")
        XCTAssertEqual(ApplicationRole.representative.badgeLabel, "代表")
        XCTAssertEqual(ApplicationRole.companion.badgeLabel, "同行")
    }

    func testEntryDefaultsToRepresentativeWithoutName() {
        let entry = ApplicationEntry(tourID: tour1, eventID: event1, repIdentityID: identityA)
        XCTAssertEqual(entry.identityRole, .representative)
        XCTAssertNil(entry.representativeName)
    }

    func testNormalizedRepresentativeName() {
        XCTAssertNil(ApplicationRole.normalizedRepresentativeName("山田", role: .representative))
        XCTAssertEqual(ApplicationRole.normalizedRepresentativeName("  山田 太郎 ", role: .companion), "山田 太郎")
        XCTAssertNil(ApplicationRole.normalizedRepresentativeName("   ", role: .companion))
        XCTAssertNil(ApplicationRole.normalizedRepresentativeName(nil, role: .companion))
    }

    func testRoleForIdentityUsesApplicationRoleWhenRep() {
        let asRep = ApplicationEntry(tourID: tour1, eventID: event1, repIdentityID: identityA)
        XCTAssertEqual(asRep.role(for: identityA), .representative)
        let asCompanionRole = ApplicationEntry(
            tourID: tour1, eventID: event1, repIdentityID: identityA,
            identityRole: .companion, representativeName: "友人"
        )
        XCTAssertEqual(asCompanionRole.role(for: identityA), .companion)
    }

    func testRoleForIdentityIsCompanionWhenOnlyInCompanions() {
        let app = ApplicationEntry(
            tourID: tour1, eventID: event1, repIdentityID: identityA,
            companions: [Companion(identityID: identityB, displayName: "B", position: 0)]
        )
        XCTAssertEqual(app.role(for: identityB), .companion)
    }

    func testRoleForUnrelatedIdentityIsNil() {
        let app = ApplicationEntry(tourID: tour1, eventID: event1, repIdentityID: identityA)
        XCTAssertNil(app.role(for: identityB))
    }

    func testNormalizedDraftDropsRepresentativeNameForRepresentative() {
        let draft = ApplicationDraft(
            tour: TourDraft(name: "T"), event: EventDraft(name: "E"), repIdentityID: identityA,
            identityRole: .representative, representativeName: "誰か"
        )
        XCTAssertNil(ApplicationStore.normalizedDraft(draft).representativeName)
        var companionDraft = draft
        companionDraft.identityRole = .companion
        XCTAssertEqual(ApplicationStore.normalizedDraft(companionDraft).representativeName, "誰か")
    }

    func testAddApplicationLocallyKeepsRoleAndName() async {
        let store = makeStore([])
        let draft = ApplicationDraft(
            tour: TourDraft(name: "T2"), event: EventDraft(name: "E2"), repIdentityID: identityA,
            identityRole: .companion, representativeName: " 友人 "
        )
        let created = await store.addApplication(draft)
        XCTAssertEqual(created?.identityRole, .companion)
        XCTAssertEqual(created?.representativeName, "友人")
    }
}
