import XCTest
@testable import Core

/// `docs/05` §5「編集後3秒デバウンス」の純粋な振る舞い。
/// 本番は 3 秒だが、テストでは短い間隔で同じ性質を検証する。
final class DebouncerTests: XCTestCase {
    /// 連続呼び出しは畳まれ、最後の 1 回だけ実行される。
    func testCoalescesBurstIntoSingleExecution() async throws {
        let counter = Counter()
        let debouncer = Debouncer(interval: .milliseconds(60))

        for _ in 0..<10 {
            await debouncer.call { await counter.increment() }
            try await Task.sleep(for: .milliseconds(5))
        }
        await debouncer.drain()

        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    /// 間隔を空けた呼び出しはそれぞれ実行される。
    func testSeparatedCallsEachExecute() async throws {
        let counter = Counter()
        let debouncer = Debouncer(interval: .milliseconds(30))

        await debouncer.call { await counter.increment() }
        await debouncer.drain()
        await debouncer.call { await counter.increment() }
        await debouncer.drain()

        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    /// `cancel()` 後は待機中の実行が起きない。
    func testCancelPreventsExecution() async throws {
        let counter = Counter()
        let debouncer = Debouncer(interval: .milliseconds(50))

        await debouncer.call { await counter.increment() }
        await debouncer.cancel()
        try await Task.sleep(for: .milliseconds(120))

        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }
}
