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
}
