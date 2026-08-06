import XCTest
@testable import Domain

@MainActor
final class StatsStoreTests: XCTestCase {
    func testLoadPopulatesSnapshot() async {
        let store = StatsStore(repository: InMemoryStatsRepository())
        await store.load()

        XCTAssertEqual(store.state, .loaded)
        XCTAssertFalse(store.snapshot?.items.isEmpty ?? true)
    }

    func testWinCountFallsBackWhenNotLoaded() {
        let store = StatsStore(repository: nil)
        let id = UUID()
        XCTAssertEqual(store.winCount(for: id, fallback: 7), 7)
        XCTAssertEqual(store.winCounts(fallback: [id: 3])[id], 3)
    }

    func testClearResetsState() async {
        let store = StatsStore(repository: InMemoryStatsRepository())
        await store.load()
        store.clear()
        XCTAssertNil(store.snapshot)
        XCTAssertEqual(store.state, .idle)
    }
}
