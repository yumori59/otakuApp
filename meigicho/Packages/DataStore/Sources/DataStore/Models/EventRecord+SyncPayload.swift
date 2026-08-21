import Foundation
import SwiftData
import Domain
import Core

/// pull 1 行（`sync-serialize.ts` の `events`）。
struct RemoteEvent {
    var id: UUID
    var tourID: UUID
    var name: String
    var venueNameRaw: String
    var eventDate: Date?
    var startsAt: Date?
    var updatedAt: Date
    var deletedAt: Date?
}

extension EventRecord: SyncableRecord {
    public static var syncCollection: SyncCollection { .events }

    public var recordID: UUID { id }
    public var recordUpdatedAt: Date { updatedAt }

    public func syncPayload() -> [String: JSONValue] {
        [
            "tour_id": .string(tourID.uuidString),
            "name": .string(name),
            "venue_name_raw": SyncPayloadBuilder.optionalString(venueNameRaw),
            "event_date": SyncPayloadBuilder.optionalDateOnly(eventDate),
            "starts_at": SyncPayloadBuilder.optionalDateTime(startsAt),
            "deleted_at": SyncPayloadBuilder.optionalDateTime(deletedAt),
        ]
    }

    static func parseRemote(_ object: [String: JSONValue]) -> RemoteEvent? {
        guard let id = SyncField.uuid(object, "id"),
              let tourID = SyncField.uuid(object, "tour_id"),
              let name = SyncField.string(object, "name"),
              let updatedAt = SyncField.dateTime(object, "updated_at")
        else { return nil }

        return RemoteEvent(
            id: id,
            tourID: tourID,
            name: name,
            venueNameRaw: SyncField.text(object, "venue_name_raw"),
            eventDate: SyncField.dateOnly(object, "event_date"),
            startsAt: SyncField.dateTime(object, "starts_at"),
            updatedAt: updatedAt,
            deletedAt: SyncField.dateTime(object, "deleted_at")
        )
    }

    public static func fetchPending(in context: ModelContext) throws -> [EventRecord] {
        let descriptor = FetchDescriptor<EventRecord>(
            predicate: #Predicate { $0.syncStateRaw != 0 },
            sortBy: [SortDescriptor(\.updatedAt)]
        )
        return try context.fetch(descriptor)
    }

    public static func fetchRecord(id: UUID, in context: ModelContext) throws -> EventRecord? {
        let descriptor = FetchDescriptor<EventRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    /// 同一ツアーの未削除 event（ツアー削除の連鎖用・`tour-edit-and-delete` D-5）。
    public static func fetchActive(tourID: UUID, in context: ModelContext) throws -> [EventRecord] {
        let descriptor = FetchDescriptor<EventRecord>(
            predicate: #Predicate { $0.tourID == tourID && $0.deletedAt == nil }
        )
        return try context.fetch(descriptor)
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
                EventRecord(
                    id: remote.id,
                    tourID: remote.tourID,
                    name: remote.name,
                    venueNameRaw: remote.venueNameRaw,
                    eventDate: remote.eventDate,
                    startsAt: remote.startsAt,
                    updatedAt: remote.updatedAt,
                    remoteUpdatedAt: remote.updatedAt,
                    syncState: .synced,
                    deletedAt: nil
                )
            )
        }
    }
}
