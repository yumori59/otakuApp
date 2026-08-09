import XCTest
import SwiftData
@testable import DataStore
import Domain

/// `docs/05` §5「編集後3秒デバウンス — Repository の書き込みフック」の配線。
/// デバウンス自体は `CoreTests.DebouncerTests`。ここでは
/// **書き込みだけが通知され、読み取りでは通知されない**ことを確かめる。
final class LocalWriteObserverTests: XCTestCase {
    func testWritesNotifyAndReadsDoNot() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let counter = Counter()
        let repository = SwiftDataIdentityRepository(
            container: container,
            onWrite: LocalWriteObserver { counter.increment() }
        )

        let identity = Identity(displayName: "自分", relation: .self, colorHex: "#0017C1")
        _ = try await repository.create(identity)
        XCTAssertEqual(counter.value, 1)

        // 読み取りでは発火しない（起動直後の初期ロードで誤発火させないため）
        _ = try await repository.list()
        _ = try await repository.pendingCount()
        XCTAssertEqual(counter.value, 1)

        var patch = IdentityPatch()
        patch.displayName = .set("改名")
        _ = try await repository.update(id: identity.id, patch)
        XCTAssertEqual(counter.value, 2)

        try await repository.delete(id: identity.id)
        XCTAssertEqual(counter.value, 3)
    }

    /// 失敗した書き込み（重複作成）は通知しない。
    func testFailedWriteDoesNotNotify() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let counter = Counter()
        let repository = SwiftDataIdentityRepository(
            container: container,
            onWrite: LocalWriteObserver { counter.increment() }
        )

        let identity = Identity(displayName: "A", relation: .other, colorHex: "#000000")
        _ = try await repository.create(identity)
        await XCTAssertThrowsErrorAsync(try await repository.create(identity))
        XCTAssertEqual(counter.value, 1)
    }

    /// 既定（`.noop`）でも従来どおり動く。
    func testDefaultObserverIsNoop() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataIdentityRepository(container: container)
        let identity = Identity(displayName: "A", relation: .other, colorHex: "#000000")
        _ = try await repository.create(identity)
        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 1)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock(); defer { lock.unlock() }
            count += 1
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // 期待どおり
    }
}
