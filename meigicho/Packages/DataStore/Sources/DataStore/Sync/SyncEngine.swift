import Foundation
import SwiftData
import Domain
import Core

/// 同期状態の受け口。UI の `SyncStatusStore` は MainActor なので Sendable コールバックで橋渡しする。
public struct SyncStatusSink: Sendable {
    public let apply: @Sendable (SyncStatus) async -> Void
    public let setPendingCount: @Sendable (Int) async -> Void

    public init(
        apply: @escaping @Sendable (SyncStatus) async -> Void,
        setPendingCount: @escaping @Sendable (Int) async -> Void = { _ in }
    ) {
        self.apply = apply
        self.setPendingCount = setPendingCount
    }

    @MainActor
    public static func binding(_ store: SyncStatusStore) -> SyncStatusSink {
        SyncStatusSink(
            apply: { status in
                await MainActor.run { store.apply(status) }
            },
            setPendingCount: { count in
                await MainActor.run { store.setPendingCount(count) }
            }
        )
    }
}

/// 全コレクションの同期サイクル（ios-sync-engine T3）。
/// push → pull → ローカル LWW マージ → cursor 更新（`docs/04` §4）。
public actor SyncEngine {
    /// 依存順（`docs/04` §4 末尾）。push も pull の適用もこの順で行う。
    static let orderedCollections: [SyncCollection] = [
        .identities,
        .memberships,
        .tours,
        .events,
        .applications,
        .applicationCompanions,
    ]

    /// `docs/04` §4.2 の reject コード。
    static let lwwRejectCode = "SYNC_LWW_REJECT"

    private let container: ModelContainer
    private let remote: any SyncRepository
    private let reachability: Reachability
    private let statusSink: SyncStatusSink
    private let cursorDefaultsKey: String

    private var currentTask: Task<Void, Never>?
    private let defaults: UserDefaults

    public init(
        container: ModelContainer,
        remote: any SyncRepository,
        reachability: Reachability,
        statusSink: SyncStatusSink,
        defaults: UserDefaults = .standard,
        cursorDefaultsKey: String = "meigicho.sync.cursor.v1"
    ) {
        self.container = container
        self.remote = remote
        self.reachability = reachability
        self.statusSink = statusSink
        self.defaults = defaults
        self.cursorDefaultsKey = cursorDefaultsKey
    }

    /// 全トリガの唯一の入口。多重起動は畳む。
    public func requestSync(reason: SyncTrigger) {
        guard currentTask == nil else { return }
        currentTask = Task { [weak self] in
            await self?.runCycle(reason: reason)
            await self?.clearTask()
        }
    }

    public func runCycleNow(reason: SyncTrigger = .manual) async {
        await runCycle(reason: reason)
    }

    private func clearTask() {
        currentTask = nil
    }

    private func runCycle(reason: SyncTrigger) async {
        let online = await reachability.isOnline
        let constrained = await reachability.isConstrained
        if !online {
            await statusSink.apply(.offline)
            return
        }
        if constrained && reason != .manual {
            return
        }

        await statusSink.apply(.syncing)
        do {
            try await drainOutbox()
            try await pullAll()
            let pending = try await countPending()
            await statusSink.setPendingCount(pending)
            await statusSink.apply(.upToDate(at: Date()))
        } catch {
            let message = (error as? AppError)?.userMessage ?? "同期に失敗しました"
            await statusSink.apply(.failed(message: message))
        }
    }

    /// Outbox のドレイン → 1 回の push。依存順（identities → … → companions）で並べる。
    private func drainOutbox() async throws {
        let context = ModelContext(container)
        let pending = try Self.pendingRecords(in: context)
        guard !pending.isEmpty else { return }

        let mutations = pending.map { record in
            SyncMutation(
                collection: type(of: record).syncCollection,
                id: record.recordID,
                updatedAt: record.recordUpdatedAt,
                payload: record.syncPayload()
            )
        }

        let result = try await remote.push(mutations: mutations)
        let accepted = Set(result.accepted)
        let rejections = Dictionary(
            result.rejected.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var rewindPoints: [Date?] = []
        for record in pending {
            if accepted.contains(record.recordID) {
                record.markSynced()
                try OutboxQueue.remove(targetID: record.recordID, in: context)
                continue
            }
            guard let rejection = rejections[record.recordID] else { continue }
            try OutboxQueue.recordFailure(
                targetID: record.recordID,
                message: "\(rejection.code): \(rejection.message)",
                in: context
            )
            if rejection.code == Self.lwwRejectCode {
                // サーバー側が新しい。次の pull で必ずサーバー値に上書きされるようにする（AC-SY-03）。
                record.markConflicted()
                rewindPoints.append(record.remoteUpdatedAt)
            }
        }
        try context.save()

        if !rewindPoints.isEmpty {
            rewindCursor(before: rewindPoints)
        }
    }

    private func pullAll() async throws {
        var cursor = lastPulledAt
        var hasMore = true
        var guardCounter = 0

        while hasMore && guardCounter < 20 {
            guardCounter += 1
            let result = try await remote.pull(
                SyncPullRequest(cursor: cursor, collections: Self.orderedCollections)
            )
            try applyPull(result)
            if let next = result.nextCursor {
                cursor = next
                lastPulledAt = next
            }
            hasMore = result.hasMore
        }
    }

    /// 依存順に適用する（親が無い状態で子を入れない）。
    private func applyPull(_ result: SyncPullResult) throws {
        let context = ModelContext(container)
        for collection in Self.orderedCollections {
            guard let rows = result.changes[collection], !rows.isEmpty else { continue }
            for object in rows {
                try Self.upsertRemote(collection: collection, object: object, in: context)
            }
        }
        try context.save()
    }

    private static func upsertRemote(
        collection: SyncCollection,
        object: [String: JSONValue],
        in context: ModelContext
    ) throws {
        switch collection {
        case .identities: try IdentityRecord.upsertRemote(object, in: context)
        case .memberships: try MembershipRecord.upsertRemote(object, in: context)
        case .tours: try TourRecord.upsertRemote(object, in: context)
        case .events: try EventRecord.upsertRemote(object, in: context)
        case .applications: try ApplicationRecord.upsertRemote(object, in: context)
        case .applicationCompanions: try ApplicationCompanionRecord.upsertRemote(object, in: context)
        }
    }

    /// 依存順に並べた push 待ちの行。
    private static func pendingRecords(in context: ModelContext) throws -> [any SyncableRecord] {
        var records: [any SyncableRecord] = []
        records += try IdentityRecord.fetchPending(in: context).map { $0 as any SyncableRecord }
        records += try MembershipRecord.fetchPending(in: context).map { $0 as any SyncableRecord }
        records += try TourRecord.fetchPending(in: context).map { $0 as any SyncableRecord }
        records += try EventRecord.fetchPending(in: context).map { $0 as any SyncableRecord }
        records += try ApplicationRecord.fetchPending(in: context).map { $0 as any SyncableRecord }
        records += try ApplicationCompanionRecord.fetchPending(in: context).map { $0 as any SyncableRecord }
        return records
    }

    private func countPending() throws -> Int {
        let context = ModelContext(container)
        return try Self.pendingRecords(in: context).count
    }

    /// LWW reject された行のサーバー確定値が cursor より古い場合、そのままでは二度と pull されない。
    /// 最後に取り込んだサーバー時刻まで cursor を巻き戻す（未 pull の行は全件再取得）。
    private func rewindCursor(before points: [Date?]) {
        if points.contains(where: { $0 == nil }) {
            lastPulledAt = nil
            return
        }
        let oldest = points.compactMap { $0 }.min()
        guard let oldest else { return }
        if let current = lastPulledAt {
            lastPulledAt = min(current, oldest)
        } else {
            lastPulledAt = oldest
        }
    }

    private var lastPulledAt: Date? {
        get { defaults.object(forKey: cursorDefaultsKey) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: cursorDefaultsKey)
            } else {
                defaults.removeObject(forKey: cursorDefaultsKey)
            }
        }
    }
}
