import XCTest
import SwiftData
@testable import DataStore
import Domain

@MainActor
final class SyncEngineTests: XCTestCase {
    func testPushThenPullMarksSyncedAndImportsRemote() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataIdentityRepository(container: container)
        let remote = FakeSyncRepository()
        let reachability = Reachability()
        await reachability.set(isOnline: true)

        let statusStore = SyncStatusStore()
        let engine = SyncEngine(
            container: container,
            remote: remote,
            reachability: reachability,
            statusSink: .binding(statusStore),
            cursorDefaultsKey: "meigicho.sync.test.\(UUID().uuidString)"
        )

        let local = Identity(displayName: "ローカル", relation: .self, colorHex: "#0017C1")
        _ = try await repository.create(local)
        let pendingBefore = try await repository.pendingCount()
        XCTAssertEqual(pendingBefore, 1)

        await engine.runCycleNow(reason: .manual)

        let pendingAfter = try await repository.pendingCount()
        XCTAssertEqual(pendingAfter, 0)
        let pushed = await remote.snapshotPushedIDs()
        XCTAssertEqual(pushed, [local.id])
        if case .upToDate = statusStore.status {
            // ok
        } else {
            XCTFail("expected upToDate, got \(statusStore.status)")
        }

        let remoteID = UUID(uuidString: "018f3c2a-aaaa-7c90-9d2a-000000000099")!
        await remote.setPullRows([[
            "id": .string(remoteID.uuidString),
            "display_name": .string("リモート"),
            "relation": .string("friend"),
            "color": .string("#FF0000"),
            "joined_on": .null,
            "note": .null,
            "history_visible": .bool(false),
            "sort_order": .number(0),
            "updated_at": .string("2026-08-01T00:00:00.000Z"),
            "deleted_at": .null,
        ]])

        await engine.runCycleNow(reason: .manual)
        let listed = try await repository.list()
        XCTAssertTrue(listed.contains(where: { $0.id == remoteID && $0.displayName == "リモート" }))
    }

    func testOfflineDoesNotCallRemote() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let remote = FakeSyncRepository()
        let reachability = Reachability()
        await reachability.set(isOnline: false)
        let statusStore = SyncStatusStore()
        let engine = SyncEngine(
            container: container,
            remote: remote,
            reachability: reachability,
            statusSink: .binding(statusStore)
        )

        await engine.runCycleNow(reason: .manual)
        let pushCount = await remote.snapshotPushCallCount()
        XCTAssertEqual(pushCount, 0)
        XCTAssertEqual(statusStore.status, .offline)
    }
}

private actor FakeSyncRepository: SyncRepository {
    private var pushedIDs: [UUID] = []
    private var pushCallCount = 0
    private var pullRows: [[String: JSONValue]] = []

    func setPullRows(_ rows: [[String: JSONValue]]) {
        pullRows = rows
    }

    func snapshotPushedIDs() -> [UUID] { pushedIDs }
    func snapshotPushCallCount() -> Int { pushCallCount }

    func pull(_ request: SyncPullRequest) async throws -> SyncPullResult {
        let rows = pullRows
        pullRows = []
        return SyncPullResult(
            changes: [.identities: rows],
            nextCursor: Date(timeIntervalSince1970: 1_800_000_000),
            hasMore: false
        )
    }

    func push(mutations: [SyncMutation]) async throws -> SyncPushResult {
        pushCallCount += 1
        pushedIDs = mutations.map(\.id)
        return SyncPushResult(
            accepted: mutations.map(\.id),
            rejected: [],
            serverTime: Date()
        )
    }
}
