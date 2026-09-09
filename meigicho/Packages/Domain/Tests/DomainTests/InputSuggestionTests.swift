import XCTest
@testable import Domain

/// T1（`docs/plans/input-history-suggestions/plan.md`）: 入力サジェストの候補計算の純粋関数テスト。
/// AC-SG-01〜08-T。
@MainActor
final class InputSuggestionTests: XCTestCase {
    // MARK: - ApplicationStore.existingArtistNames（AC-SG-01-T）

    func test_existingArtistNames_dedupes_excludesBlank_sortsAscending() {
        let store = ApplicationStore()
        store.tours = ["STELLARIS", "STELLARIS", "", "  ", "AURORA"].map { name in
            Tour(name: "tour-\(UUID())", artistNameRaw: name)
        }

        XCTAssertEqual(store.existingArtistNames, ["AURORA", "STELLARIS"])
    }

    // MARK: - ApplicationStore.existingVenueNames（AC-SG-02-T）

    func test_existingVenueNames_dedupes_excludesBlank_sortsAscending() {
        let store = ApplicationStore()
        let tourID = UUID()
        let names = ["マリンメッセ福岡", "", "東京ドーム", "マリンメッセ福岡"]
        store.events = names.map { name in
            EventEntity(tourID: tourID, name: "event-\(UUID())", venueNameRaw: name)
        }

        XCTAssertEqual(store.existingVenueNames, ["マリンメッセ福岡", "東京ドーム"].sorted())
    }

    // MARK: - InputSuggestion.match（AC-SG-03〜06-T）

    func test_match_partialCaseInsensitive() {
        let result = InputSuggestion.match(["STELLARIS ARENA TOUR 2026"], query: "arena")
        XCTAssertEqual(result, ["STELLARIS ARENA TOUR 2026"])
    }

    func test_match_excludesExactMatch_caseInsensitive() {
        let result = InputSuggestion.match(["STELLARIS"], query: "stellaris")
        XCTAssertEqual(result, [])
    }

    func test_match_emptyOrBlankQuery_returnsEmpty() {
        let candidates = ["STELLARIS", "AURORA"]
        XCTAssertEqual(InputSuggestion.match(candidates, query: ""), [])
        XCTAssertEqual(InputSuggestion.match(candidates, query: "   "), [])
    }

    func test_match_limitsToFive() {
        let candidates = (1...7).map { "会場\($0)" }
        let result = InputSuggestion.match(candidates, query: "会場")
        XCTAssertEqual(result.count, 5)
    }

    // MARK: - ApplicationStore.artistName(forTourNamed:)（AC-SG-07-T）

    func test_artistNameForTourNamed_returnsNonEmptyArtistForExactMatch() {
        let store = ApplicationStore()
        store.tours = [
            Tour(name: "TOUR A", artistNameRaw: "AURORA"),
            Tour(name: "TOUR B", artistNameRaw: "")
        ]

        XCTAssertEqual(store.artistName(forTourNamed: "TOUR A"), "AURORA")
        XCTAssertNil(store.artistName(forTourNamed: "TOUR B"))
        XCTAssertNil(store.artistName(forTourNamed: "TOUR UNKNOWN"))
    }

    // MARK: - 回帰: existingTourNames + match が既存 filteredTours と同じ結果になる（AC-SG-08-T）

    func test_existingTourNamesWithMatch_matchesLegacyFilteredToursBehavior() {
        let store = ApplicationStore()
        store.tours = [
            Tour(name: "STELLARIS ARENA TOUR 2026", artistNameRaw: "STELLARIS"),
            Tour(name: "AURORA HALL TOUR", artistNameRaw: "AURORA"),
            Tour(name: "stellaris winter live", artistNameRaw: "STELLARIS")
        ]
        let query = "stella"

        // 旧 `ApplicationFormView.filteredTours` と同じ規則（部分一致・大小無視・完全一致除外・上限なし）
        let legacy = store.existingTourNames.filter {
            $0.localizedCaseInsensitiveContains(query) && $0.caseInsensitiveCompare(query) != .orderedSame
        }

        let result = InputSuggestion.match(store.existingTourNames, query: query, limit: Int.max)

        XCTAssertEqual(result, legacy)
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - 公演名サジェスト（`docs/plans/event-name-suggestion/plan.md`、AC-ES-01〜05-T）

    // MARK: InputSuggestion.candidates(fromOrdered:)（AC-ES-01-T）

    func test_candidatesFromOrdered_preservesInputOrder_dedupesFirstWins_excludesBlank() {
        let result = InputSuggestion.candidates(fromOrdered: ["B", "", "  ", "A", "B"])

        XCTAssertEqual(result, ["B", "A"])
    }

    // MARK: ApplicationStore.existingEventNames（AC-ES-02〜03-T）

    func test_existingEventNames_ordersByEventDateDescending_nilLast() {
        let store = ApplicationStore()
        let tourID = UUID()
        let older = EventEntity(
            tourID: tourID, name: "08-01公演", venueNameRaw: "",
            eventDate: Date(timeIntervalSince1970: 1_754_000_000)
        )
        let newer = EventEntity(
            tourID: tourID, name: "10-05公演", venueNameRaw: "",
            eventDate: Date(timeIntervalSince1970: 1_759_600_000)
        )
        let noDate = EventEntity(tourID: tourID, name: "nil公演", venueNameRaw: "", eventDate: nil)
        // 配列順はバラバラに積む（並び順は store 側の責務であることを検証する）
        store.events = [older, noDate, newer]

        XCTAssertEqual(store.existingEventNames, ["10-05公演", "08-01公演", "nil公演"])
    }

    func test_existingEventNames_dedupesSameName_keepsOneEntry() {
        let store = ApplicationStore()
        let tourID = UUID()
        store.events = [
            EventEntity(
                tourID: tourID, name: "X 福岡公演", venueNameRaw: "",
                eventDate: Date(timeIntervalSince1970: 1_754_000_000)
            ),
            EventEntity(
                tourID: tourID, name: "X 福岡公演", venueNameRaw: "",
                eventDate: Date(timeIntervalSince1970: 1_759_600_000)
            )
        ]

        XCTAssertEqual(store.existingEventNames.filter { $0 == "X 福岡公演" }.count, 1)
    }

    // MARK: ApplicationStore.eventAutofill(forEventNamed:)（AC-ES-04-T）

    func test_eventAutofill_returnsTourArtistVenue_forMostRecentMatch() {
        let store = ApplicationStore()
        let tour = Tour(name: "T", artistNameRaw: "A")
        store.tours = [tour]
        let older = EventEntity(
            tourID: tour.id, name: "X 福岡公演", venueNameRaw: "旧会場",
            eventDate: Date(timeIntervalSince1970: 1_754_000_000)
        )
        let newer = EventEntity(
            tourID: tour.id, name: "X 福岡公演", venueNameRaw: "マリンメッセ福岡",
            eventDate: Date(timeIntervalSince1970: 1_759_600_000)
        )
        store.events = [older, newer]

        let result = store.eventAutofill(forEventNamed: "X 福岡公演")

        XCTAssertEqual(result, EventNameAutofill(tourName: "T", artistNameRaw: "A", venueNameRaw: "マリンメッセ福岡"))
    }

    func test_eventAutofill_emptyVenue_returnsNilForVenueOnly() {
        let store = ApplicationStore()
        let tour = Tour(name: "T", artistNameRaw: "A")
        store.tours = [tour]
        store.events = [EventEntity(tourID: tour.id, name: "空欄会場公演", venueNameRaw: "")]

        let result = store.eventAutofill(forEventNamed: "空欄会場公演")

        XCTAssertEqual(result, EventNameAutofill(tourName: "T", artistNameRaw: "A", venueNameRaw: nil))
    }

    func test_eventAutofill_emptyArtistName_returnsNilArtistOnly() {
        let store = ApplicationStore()
        let tour = Tour(name: "T2", artistNameRaw: "")
        store.tours = [tour]
        store.events = [EventEntity(tourID: tour.id, name: "公演Z", venueNameRaw: "会場Z")]

        let result = store.eventAutofill(forEventNamed: "公演Z")

        XCTAssertEqual(result, EventNameAutofill(tourName: "T2", artistNameRaw: nil, venueNameRaw: "会場Z"))
    }

    func test_eventAutofill_missingTour_returnsVenueOnly() {
        let store = ApplicationStore()
        let missingTourID = UUID()
        store.tours = []
        store.events = [EventEntity(tourID: missingTourID, name: "未紐付け公演", venueNameRaw: "会場X")]

        let result = store.eventAutofill(forEventNamed: "未紐付け公演")

        XCTAssertEqual(result, EventNameAutofill(tourName: nil, artistNameRaw: nil, venueNameRaw: "会場X"))
    }

    func test_eventAutofill_unknownName_returnsNil() {
        let store = ApplicationStore()
        store.tours = [Tour(name: "T", artistNameRaw: "A")]
        store.events = [EventEntity(tourID: UUID(), name: "既知の公演", venueNameRaw: "会場")]

        XCTAssertNil(store.eventAutofill(forEventNamed: "存在しない公演"))
    }

    func test_eventAutofill_trimsBothSidesBeforeComparing() {
        let store = ApplicationStore()
        let tour = Tour(name: "T", artistNameRaw: "A")
        store.tours = [tour]
        store.events = [EventEntity(tourID: tour.id, name: "  空白付き公演  ", venueNameRaw: "会場Y")]

        let byTrimmedQuery = store.eventAutofill(forEventNamed: "空白付き公演")
        let byUntrimmedQuery = store.eventAutofill(forEventNamed: "  空白付き公演  ")

        XCTAssertEqual(byTrimmedQuery, EventNameAutofill(tourName: "T", artistNameRaw: "A", venueNameRaw: "会場Y"))
        XCTAssertEqual(byUntrimmedQuery, byTrimmedQuery)
    }

    // MARK: existingEventNames + InputSuggestion.match（AC-ES-05-T）

    func test_existingEventNamesWithMatch_partialCaseInsensitive() {
        let store = ApplicationStore()
        store.events = [EventEntity(tourID: UUID(), name: "STELLARIS ARENA TOUR 2026 -福岡公演-", venueNameRaw: "")]

        XCTAssertEqual(
            InputSuggestion.match(store.existingEventNames, query: "福岡"),
            ["STELLARIS ARENA TOUR 2026 -福岡公演-"]
        )
    }

    func test_existingEventNamesWithMatch_emptyQuery_returnsEmpty() {
        let store = ApplicationStore()
        store.events = [EventEntity(tourID: UUID(), name: "公演A", venueNameRaw: "")]

        XCTAssertEqual(InputSuggestion.match(store.existingEventNames, query: ""), [])
    }

    func test_existingEventNamesWithMatch_excludesExactMatch() {
        let store = ApplicationStore()
        store.events = [EventEntity(tourID: UUID(), name: "公演A", venueNameRaw: "")]

        XCTAssertEqual(InputSuggestion.match(store.existingEventNames, query: "公演A"), [])
    }

    func test_existingEventNamesWithMatch_limitsToNewestFive() {
        let store = ApplicationStore()
        let tourID = UUID()
        let events = (0..<6).map { index in
            EventEntity(
                tourID: tourID, name: "福岡公演\(index)", venueNameRaw: "",
                eventDate: Date(timeIntervalSince1970: 1_750_000_000 + Double(index) * 100_000)
            )
        }
        // 配列順はバラバラに積む（新しい順への並び替えは store 側の責務）
        store.events = events.reversed()

        let result = InputSuggestion.match(store.existingEventNames, query: "福岡")

        XCTAssertEqual(result, ["福岡公演5", "福岡公演4", "福岡公演3", "福岡公演2", "福岡公演1"])
    }
}
