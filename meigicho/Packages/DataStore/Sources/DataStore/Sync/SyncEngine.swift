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

/// identities のみの同期サイクル（ios-sync-engine T2）。
public actor SyncEngine {
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
        cursorDefaultsKey: String = "meigicho.sync.cursor.identities"
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
            try await drainIdentities()
            try await pullIdentities()
            let pending = try await countPending()
            await statusSink.setPendingCount(pending)
            await statusSink.apply(.upToDate(at: Date()))
        } catch {
            let message = (error as? AppError)?.userMessage ?? "同期に失敗しました"
            await statusSink.apply(.failed(message: message))
        }
    }

    private func drainIdentities() async throws {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<IdentityRecord>(
            predicate: #Predicate { $0.syncStateRaw != 0 },
            sortBy: [SortDescriptor(\.updatedAt)]
        )
        let pending = try context.fetch(descriptor)
        guard !pending.isEmpty else { return }

        let mutations = pending.map { record in
            SyncMutation(
                collection: .identities,
                id: record.id,
                updatedAt: record.updatedAt,
                payload: record.syncPayload()
            )
        }

        let result = try await remote.push(mutations: mutations)
        let accepted = Set(result.accepted)

        for record in pending where accepted.contains(record.id) {
            record.syncState = .synced
            record.remoteUpdatedAt = record.updatedAt
            try removeOutbox(targetID: record.id, in: context)
        }
        try context.save()
    }

    private func pullIdentities() async throws {
        var cursor = lastPulledAt
        var hasMore = true
        var guardCounter = 0

        while hasMore && guardCounter < 20 {
            guardCounter += 1
            let result = try await remote.pull(
                SyncPullRequest(cursor: cursor, collections: [.identities])
            )
            try applyPull(result)
            if let next = result.nextCursor {
                cursor = next
                lastPulledAt = next
            }
            hasMore = result.hasMore
        }
    }

    private func applyPull(_ result: SyncPullResult) throws {
        let context = ModelContext(container)
        let rows = result.changes[.identities] ?? []
        for object in rows {
            guard let remote = IdentityRecord.parseRemote(object) else { continue }
            if let local = try fetchRecord(id: remote.id, in: context) {
                let decision = LWWResolver.resolve(
                    localUpdatedAt: local.updatedAt,
                    remoteUpdatedAt: remote.updatedAt,
                    remoteDeletedAt: remote.deletedAt
                )
                switch decision {
                case .keepLocal:
                    continue
                case .deleteLocal, .takeRemote:
                    local.applyRemote(
                        displayName: remote.displayName,
                        relationRaw: remote.relationRaw,
                        colorHex: remote.colorHex,
                        joinedOn: remote.joinedOn,
                        note: remote.note,
                        historyVisible: remote.historyVisible,
                        sortOrder: remote.sortOrder,
                        updatedAt: remote.updatedAt,
                        deletedAt: remote.deletedAt
                    )
                }
            } else if remote.deletedAt == nil {
                let record = IdentityRecord(
                    id: remote.id,
                    displayName: remote.displayName,
                    relationRaw: remote.relationRaw,
                    colorHex: remote.colorHex,
                    joinedOn: remote.joinedOn,
                    note: remote.note,
                    historyVisible: remote.historyVisible,
                    sortOrder: remote.sortOrder,
                    updatedAt: remote.updatedAt,
                    remoteUpdatedAt: remote.updatedAt,
                    syncState: .synced,
                    deletedAt: nil
                )
                context.insert(record)
            }
        }
        try context.save()
    }

    private func countPending() throws -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<IdentityRecord>(
            predicate: #Predicate { $0.syncStateRaw != 0 }
        )
        return try context.fetch(descriptor).count
    }

    private func fetchRecord(id: UUID, in context: ModelContext) throws -> IdentityRecord? {
        let descriptor = FetchDescriptor<IdentityRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    private func removeOutbox(targetID: UUID, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<OutboxEntry>(
            predicate: #Predicate { $0.targetID == targetID }
        )
        for entry in try context.fetch(descriptor) {
            context.delete(entry)
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
