import Foundation
import SwiftData
import Domain

extension IdentityRecord: SyncableRecord {
    public static var syncCollection: SyncCollection { .identities }

    public var recordID: UUID { id }
    public var recordUpdatedAt: Date { updatedAt }

    public static func fetchPending(in context: ModelContext) throws -> [IdentityRecord] {
        let descriptor = FetchDescriptor<IdentityRecord>(
            predicate: #Predicate { $0.syncStateRaw != 0 },
            sortBy: [SortDescriptor(\.updatedAt)]
        )
        return try context.fetch(descriptor)
    }

    public static func fetchRecord(id: UUID, in context: ModelContext) throws -> IdentityRecord? {
        let descriptor = FetchDescriptor<IdentityRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    public static func upsertRemote(_ object: [String: JSONValue], in context: ModelContext) throws {
        guard let remote = parseRemote(object) else { return }
        if let local = try fetchRecord(id: remote.id, in: context) {
            guard SyncMerge.shouldTakeRemote(
                localSyncState: local.syncState,
                localUpdatedAt: local.updatedAt,
                remoteUpdatedAt: remote.updatedAt,
                remoteDeletedAt: remote.deletedAt
            ) else { return }
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
            try OutboxQueue.remove(targetID: local.id, in: context)
        } else if remote.deletedAt == nil {
            context.insert(
                IdentityRecord(
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
            )
        }
    }
}
