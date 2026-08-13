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

    func testPermanentRejectionMarksSyncStatusFailed() async throws {
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

        await remote.setRejectAll(code: "SYNC_APPLY_FAILED", message: "適用に失敗しました")
        await engine.runCycleNow(reason: .manual)

        if case .failed(let message) = statusStore.status {
            XCTAssertTrue(message.contains("1件"), "expected message to mention 1件, got \(message)")
        } else {
            XCTFail("expected failed, got \(statusStore.status)")
        }
    }

    func testLWWRejectionOnlyStillReportsUpToDate() async throws {
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

        await remote.setRejectAll(code: "SYNC_LWW_REJECT", message: "サーバー側が新しい")
        await engine.runCycleNow(reason: .manual)

        if case .upToDate = statusStore.status {
            // ok
        } else {
            XCTFail("expected upToDate, got \(statusStore.status)")
        }
    }

    func testFailureMessageBoundaries() {
        XCTAssertNil(SyncEngine.failureMessage(for: []))

        let single = SyncEngine.failureMessage(for: [
            SyncPushRejection(id: UUID(), code: "PLAN_LIMIT_IDENTITY", message: "limit reached"),
        ])
        XCTAssertEqual(single, "1件の変更を同期できませんでした（無料プランの上限に達しました）")

        let multiple = SyncEngine.failureMessage(for: [
            SyncPushRejection(id: UUID(), code: "SYNC_APPLY_FAILED", message: "a"),
            SyncPushRejection(id: UUID(), code: "SYNC_APPLY_FAILED", message: "b"),
        ])
        XCTAssertEqual(multiple, "2件の変更を同期できませんでした")
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
    private var rejectionCode: String?
    private var rejectionMessage: String = ""

    func setPullRows(_ rows: [[String: JSONValue]]) {
        pullRows = rows
    }

    func setRejectAll(code: String, message: String) {
        rejectionCode = code
        rejectionMessage = message
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
        if let rejectionCode {
            return SyncPushResult(
                accepted: [],
                rejected: mutations.map { SyncPushRejection(id: $0.id, code: rejectionCode, message: rejectionMessage) },
                serverTime: Date()
            )
        }
        return SyncPushResult(
            accepted: mutations.map(\.id),
            rejected: [],
            serverTime: Date()
        )
    }
}
