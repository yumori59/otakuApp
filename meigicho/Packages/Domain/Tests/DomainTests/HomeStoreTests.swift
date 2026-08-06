import XCTest
@testable import Domain

@MainActor
final class HomeStoreTests: XCTestCase {
    func testLoadPopulatesSummary() async {
        let store = HomeStore(repository: InMemoryHomeRepository())
        await store.load()

        XCTAssertNotNil(store.summary)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.summary?.identityCount, SampleData.identities.count)
    }

    func testClearResetsState() async {
        let store = HomeStore(repository: InMemoryHomeRepository())
        await store.load()
        store.clear()

        XCTAssertNil(store.summary)
        XCTAssertEqual(store.state, .idle)
    }
}
