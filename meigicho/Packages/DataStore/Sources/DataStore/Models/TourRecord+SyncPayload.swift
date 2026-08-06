import Foundation
import SwiftData
import Domain
import Core

/// pull 1 行（`sync-serialize.ts` の `tours`）。
struct RemoteTour {
    var id: UUID
    var name: String
    var artistNameRaw: String
    var updatedAt: Date
    var deletedAt: Date?
}

extension TourRecord: SyncableRecord {
    public static var syncCollection: SyncCollection { .tours }

    public var recordID: UUID { id }
    public var recordUpdatedAt: Date { updatedAt }

    public func syncPayload() -> [String: JSONValue] {
        [
            "name": .string(name),
            "artist_name_raw": SyncPayloadBuilder.optionalString(artistNameRaw),
            "deleted_at": SyncPayloadBuilder.optionalDateTime(deletedAt),
        ]
    }

    static func parseRemote(_ object: [String: JSONValue]) -> RemoteTour? {
        guard let id = SyncField.uuid(object, "id"),
              let name = SyncField.string(object, "name"),
              let updatedAt = SyncField.dateTime(object, "updated_at")
        else { return nil }

        return RemoteTour(
            id: id,
            name: name,
            artistNameRaw: SyncField.text(object, "artist_name_raw"),
            updatedAt: updatedAt,
            deletedAt: SyncField.dateTime(object, "deleted_at")
        )
    }

    public static func fetchPending(in context: ModelContext) throws -> [TourRecord] {
        let descriptor = FetchDescriptor<TourRecord>(
            predicate: #Predicate { $0.syncStateRaw != 0 },
            sortBy: [SortDescriptor(\.updatedAt)]
        )
        return try context.fetch(descriptor)
    }

    public static func fetchRecord(id: UUID, in context: ModelContext) throws -> TourRecord? {
        let descriptor = FetchDescriptor<TourRecord>(
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
            local.applyRemote(remote)
            try OutboxQueue.remove(targetID: local.id, in: context)
        } else if remote.deletedAt == nil {
            context.insert(
                TourRecord(
                    id: remote.id,
                    name: remote.name,
                    artistNameRaw: remote.artistNameRaw,
                    updatedAt: remote.updatedAt,
                    remoteUpdatedAt: remote.updatedAt,
                    syncState: .synced,
                    deletedAt: nil
                )
            )
        }
    }
}
