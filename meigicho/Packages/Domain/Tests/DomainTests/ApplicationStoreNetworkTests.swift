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

    // MARK: - T2: updateApplication（申込 + tour/event 付け替え）

    /// ツアー名変更でツアーが付け替わり（新 tour）、リポジトリの戻り値で `tours`/`events` が整合すること。
    /// `plan.md` 135 行目: T2 は Store の薄い委譲だが、この整合部分だけは Store テストで押さえる。
    func testUpdateApplicationReconcilesToursAndEventsFromRepositoryResult() async {
        let oldTour = Tour(id: tour1, name: "旧ツアー", artistNameRaw: "ARTIST", updatedAt: today)
        let existingEvent = EventEntity(
            id: event1, tourID: tour1, name: "公演A", venueNameRaw: "会場A",
            eventDate: day(2026, 9, 13), updatedAt: today
        )
        let existing = entry(id: UUID(), eventID: event1, status: .applied, seatRaw: "")
        let newTourID = UUID(uuidString: "00000000-0000-7000-8000-000000000999")!

        let repository = FakeApplicationRepository(pages: [])
        await repository.setUpdateScopedResult { id, plan in
            var updated = existing
            updated.tourID = plan.tourDraft?.id ?? updated.tourID
            updated.status = plan.applicationPatch.status.applied(to: updated.status) ?? updated.status
            return updated
        }
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        store.applications = [existing]
        store.tours = [oldTour]
        store.events = [existingEvent]

        var input = ApplicationEditFormInput(
            eventName: existingEvent.name,
            tourName: "新ツアー",
            artistNameRaw: oldTour.artistNameRaw,
            venueNameRaw: existingEvent.venueNameRaw,
            eventDate: existingEvent.eventDate,
            repIdentityID: existing.repIdentityID,
            status: .won
        )
        input.appliedOn = existing.appliedOn
        input.resultOn = existing.resultOn
        input.seatRaw = existing.seatRaw
        input.note = existing.note

        let updated = await store.updateApplication(existing.id, input: input)

        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.status, .won)
        let plans = await repository.updateScopedPlans
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].tourDraft?.name, "新ツアー")

        // リポジトリが返した tourID（= plan.tourDraft.id）で新ツアーが 1 件増え、旧ツアーは残る
        XCTAssertEqual(store.tours.count, 2, "付け替え先の新ツアーが増える")
        XCTAssertEqual(store.tour(for: updated!.tourID)?.name, "新ツアー")
        XCTAssertEqual(store.tour(for: tour1)?.name, "旧ツアー", "旧ツアー自体は書き換えない")
        XCTAssertNil(store.writeError)
        XCTAssertFalse(store.isSaving)
    }

    /// 【中】既存の別ツアーに吸収されたとき、`tourDraft.artistNameRaw`（編集前の文脈から計算した値）で
    /// 吸収先の既存ツアーの `artistNameRaw` を上書きしない（review #3）。
    func testUpdateApplicationAbsorbedIntoExistingTourKeepsExistingArtistNameRaw() async {
        let oldTour = Tour(id: tour1, name: "旧ツアー", artistNameRaw: "編集前アーティスト", updatedAt: today)
        let absorbedTourID = UUID(uuidString: "00000000-0000-7000-8000-000000000888")!
        let absorbedTour = Tour(
            id: absorbedTourID, name: "既存ツアー",
            artistNameRaw: "既存アーティスト（保持されるべき）", updatedAt: today
        )
        let existingEvent = EventEntity(
            id: event1, tourID: tour1, name: "公演A", venueNameRaw: "会場A",
            eventDate: day(2026, 9, 13), updatedAt: today
        )
        let existing = entry(id: UUID(), eventID: event1, status: .applied, seatRaw: "")

        let repository = FakeApplicationRepository(pages: [])
        // サーバーの find-or-create が「既存ツアー」に吸収した想定。
        // 返ってくる tourID（= absorbedTourID）は plan.tourDraft.id（新規発行）とは異なる
        await repository.setUpdateScopedResult { id, plan in
            var updated = existing
            updated.tourID = absorbedTourID
            updated.status = plan.applicationPatch.status.applied(to: updated.status) ?? updated.status
            return updated
        }
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        store.applications = [existing]
        store.tours = [oldTour, absorbedTour]
        store.events = [existingEvent]

        var input = ApplicationEditFormInput(
            eventName: existingEvent.name,
            tourName: "既存ツアー",
            artistNameRaw: "編集画面でうっかり入力してしまったアーティスト名",
            venueNameRaw: existingEvent.venueNameRaw,
            eventDate: existingEvent.eventDate,
            repIdentityID: existing.repIdentityID,
            status: existing.status
        )
        input.appliedOn = existing.appliedOn
        input.resultOn = existing.resultOn
        input.seatRaw = existing.seatRaw
        input.note = existing.note

        let updated = await store.updateApplication(existing.id, input: input)

        XCTAssertEqual(updated?.tourID, absorbedTourID)
        XCTAssertEqual(store.tours.count, 2, "吸収先は既存ツアーなのでツアーは増えない")
        XCTAssertEqual(
            store.tour(for: absorbedTourID)?.artistNameRaw,
            "既存アーティスト（保持されるべき）",
            "吸収先の既存 artistNameRaw を編集前文脈の値で上書きしない"
        )
    }

    /// 【中】repository なし（Preview / テスト）のローカル編集経路でも、
    /// サーバーの find-or-create と同じくツアー名の一致で既存ツアーに吸収し、重複作成しない。
    func testLocalEditAbsorbsIntoExistingTourByNameWithoutRepository() async {
        let oldTour = Tour(id: tour1, name: "旧ツアー", artistNameRaw: "旧アーティスト", updatedAt: today)
        let existingTourID = UUID(uuidString: "00000000-0000-7000-8000-000000000777")!
        let existingTour = Tour(id: existingTourID, name: "既存ツアー", artistNameRaw: "既存アーティスト", updatedAt: today)
        let existingEvent = EventEntity(
            id: event1, tourID: tour1, name: "公演A", venueNameRaw: "会場A",
            eventDate: day(2026, 9, 13), updatedAt: today
        )
        let existing = entry(id: UUID(), eventID: event1, status: .applied, seatRaw: "")

        let store = ApplicationStore(now: { [today] in today }) // repository なし = ローカル経路
        store.applications = [existing]
        store.tours = [oldTour, existingTour]
        store.events = [existingEvent]

        var input = ApplicationEditFormInput(
            eventName: existingEvent.name,
            tourName: "既存ツアー",
            artistNameRaw: oldTour.artistNameRaw,
            venueNameRaw: existingEvent.venueNameRaw,
            eventDate: existingEvent.eventDate,
            repIdentityID: existing.repIdentityID,
            status: existing.status
        )
        input.appliedOn = existing.appliedOn
        input.resultOn = existing.resultOn
        input.seatRaw = existing.seatRaw
        input.note = existing.note

        let updated = await store.updateApplication(existing.id, input: input)

        XCTAssertEqual(updated?.tourID, existingTourID, "同名の既存ツアーに吸収され、新規 id は使わない")
        XCTAssertEqual(store.tours.count, 2, "ツアーが重複作成されない")
        XCTAssertEqual(store.tour(for: existingTourID)?.artistNameRaw, "既存アーティスト", "吸収先の既存値を保持する")
    }

    /// 【中】`InMemoryApplicationRepository.updateScoped` 単体でも、同名の既存ツアーに吸収し重複作成しない。
    func testInMemoryRepositoryUpdateScopedAbsorbsIntoExistingTourByName() async throws {
        let oldTour = Tour(id: tour1, name: "旧ツアー", artistNameRaw: "旧アーティスト", updatedAt: today)
        let existingTourID = UUID(uuidString: "00000000-0000-7000-8000-000000000777")!
        let existingTour = Tour(id: existingTourID, name: "既存ツアー", artistNameRaw: "既存アーティスト", updatedAt: today)
        let existing = entry(id: UUID(), eventID: event1)

        let repository = InMemoryApplicationRepository(items: [existing], tours: [oldTour, existingTour])
        let plan = ApplicationEditPlan(
            applicationPatch: ApplicationPatch(),
            tourDraft: TourDraft(name: "既存ツアー"), // 新規 UUID（既存 id とは異なる）を発行済みの想定
            eventDraft: nil
        )

        let updated = try await repository.updateScoped(applicationID: existing.id, plan: plan)

        XCTAssertEqual(updated.tourID, existingTourID, "同名の既存ツアーに吸収される")
    }

    func testUpdateApplicationFailureSetsWriteErrorAndKeepsApplicationUnchanged() async {
        let existing = entry(id: UUID(), eventID: event1, status: .applied, seatRaw: "")
        let existingTour = Tour(id: tour1, name: "TOUR", updatedAt: today)
        let existingEvent = EventEntity(id: event1, tourID: tour1, name: "公演A", updatedAt: today)
        let repository = FakeApplicationRepository(pages: [])
        await repository.setFailure(.offline)
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        store.applications = [existing]
        store.tours = [existingTour]
        store.events = [existingEvent]

        let input = ApplicationEditFormInput(
            eventName: existingEvent.name,
            tourName: existingTour.name,
            repIdentityID: existing.repIdentityID,
            status: .won
        )
        let updated = await store.updateApplication(existing.id, input: input)

        XCTAssertNil(updated)
        XCTAssertEqual(store.writeError, .offline)
        XCTAssertEqual(store.applications[0].status, .applied, "失敗時は書き換えない（楽観更新しない・D-5）")
    }

    // MARK: - T3: deleteApplication（申込削除）

    func testDeleteApplicationSuccessRemovesFromApplications() async {
        let existing = entry(id: UUID(), eventID: event1)
        let other = entry(id: UUID(), eventID: event1)
        let repository = FakeApplicationRepository(pages: [])
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        store.applications = [existing, other]

        let result = await store.deleteApplication(existing.id)

        XCTAssertTrue(result)
        XCTAssertEqual(store.applications.map(\.id), [other.id])
        XCTAssertNil(store.writeError)
        let calls = await repository.deleteCalls
        XCTAssertEqual(calls, [existing.id])
    }

    func testDeleteApplicationFailureKeepsApplicationsUnchangedAndSetsWriteError() async {
        let existing = entry(id: UUID(), eventID: event1)
        let repository = FakeApplicationRepository(pages: [])
        await repository.setFailure(.offline)
        let store = ApplicationStore(repository: repository, now: { [today] in today })
        store.applications = [existing]

        let result = await store.deleteApplication(existing.id)

        XCTAssertFalse(result)
        XCTAssertEqual(store.applications.map(\.id), [existing.id], "失敗時は削除しない（楽観更新しない）")
        XCTAssertEqual(store.writeError, .offline)
    }

    func testDeleteApplicationWithoutRepositoryRemovesLocally() async {
        let existing = entry(id: UUID(), eventID: event1)
        let store = ApplicationStore(now: { [today] in today }) // repository なし = ローカル経路
        store.applications = [existing]

        let result = await store.deleteApplication(existing.id)

        XCTAssertTrue(result)
        XCTAssertTrue(store.applications.isEmpty)
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
    private(set) var updateScopedPlans: [ApplicationEditPlan] = []
    private(set) var deleteCalls: [UUID] = []
    private var pages: [ApplicationPage]
    private let alwaysMore: Bool
    private let itemsPerPage: Int
    private var failure: AppError?
    private var createResult: (@Sendable (ApplicationDraft) -> ApplicationEntry)?
    private var updateResult: (@Sendable (UUID, ApplicationPatch) -> ApplicationEntry)?
    private var updateScopedResult: (@Sendable (UUID, ApplicationEditPlan) -> ApplicationEntry)?

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
    func setUpdateScopedResult(_ handler: @escaping @Sendable (UUID, ApplicationEditPlan) -> ApplicationEntry) {
        updateScopedResult = handler
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

    func updateScoped(applicationID: UUID, plan: ApplicationEditPlan) async throws -> ApplicationEntry {
        updateScopedPlans.append(plan)
        if let failure { throw failure }
        if let updateScopedResult { return updateScopedResult(applicationID, plan) }
        throw AppError.notFound
    }

    func delete(id: UUID) async throws {
        deleteCalls.append(id)
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
