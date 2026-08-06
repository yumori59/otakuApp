import Foundation
import SwiftData
import Domain
import Core

/// pull 1 行（`sync-serialize.ts` の `applications`）。**`tour_id` は来ない**。
struct RemoteApplication {
    var id: UUID
    var eventID: UUID
    var repIdentityID: UUID
    var repMembershipID: UUID?
    var roundName: String?
    var appliedOn: Date?
    var resultOn: Date?
    var statusRaw: String
    var seatRaw: String
    var ticketCount: Int
    var priceYen: Int?
    var note: String
    var updatedAt: Date
    var deletedAt: Date?
}

/// pull 1 行（`sync-serialize.ts` の `application_companions`）。
struct RemoteApplicationCompanion {
    var id: UUID
    var applicationID: UUID
    var identityID: UUID?
    var displayName: String
    var position: Int
    var updatedAt: Date
    var deletedAt: Date?
}

extension ApplicationRecord: SyncableRecord {
    public static var syncCollection: SyncCollection { .applications }

    public var recordID: UUID { id }
    public var recordUpdatedAt: Date { updatedAt }

    public func syncPayload() -> [String: JSONValue] {
        [
            "event_id": .string(eventID.uuidString),
            "rep_identity_id": .string(repIdentityID.uuidString),
            "rep_membership_id": SyncPayloadBuilder.optionalUUID(repMembershipID),
            "round_name": SyncPayloadBuilder.optionalString(roundName),
            "applied_on": SyncPayloadBuilder.optionalDateOnly(appliedOn),
            "result_on": SyncPayloadBuilder.optionalDateOnly(resultOn),
            "status": .string(statusRaw),
            "seat_raw": SyncPayloadBuilder.optionalString(seatRaw),
            "ticket_count": .number(Double(ticketCount)),
            "price_yen": SyncPayloadBuilder.optionalInt(priceYen),
            "note": SyncPayloadBuilder.optionalString(note),
            "deleted_at": SyncPayloadBuilder.optionalDateTime(deletedAt),
        ]
    }

    static func parseRemote(_ object: [String: JSONValue]) -> RemoteApplication? {
        guard let id = SyncField.uuid(object, "id"),
              let eventID = SyncField.uuid(object, "event_id"),
              let repIdentityID = SyncField.uuid(object, "rep_identity_id"),
              let statusRaw = SyncField.string(object, "status"),
              let updatedAt = SyncField.dateTime(object, "updated_at")
        else { return nil }

        return RemoteApplication(
            id: id,
            eventID: eventID,
            repIdentityID: repIdentityID,
            repMembershipID: SyncField.uuid(object, "rep_membership_id"),
            roundName: SyncField.string(object, "round_name"),
            appliedOn: SyncField.dateOnly(object, "applied_on"),
            resultOn: SyncField.dateOnly(object, "result_on"),
            statusRaw: statusRaw,
            seatRaw: SyncField.text(object, "seat_raw"),
            ticketCount: SyncField.int(object, "ticket_count") ?? 1,
            priceYen: SyncField.int(object, "price_yen"),
            note: SyncField.text(object, "note"),
            updatedAt: updatedAt,
            deletedAt: SyncField.dateTime(object, "deleted_at")
        )
    }

    public static func fetchPending(in context: ModelContext) throws -> [ApplicationRecord] {
        let descriptor = FetchDescriptor<ApplicationRecord>(
            predicate: #Predicate { $0.syncStateRaw != 0 },
            sortBy: [SortDescriptor(\.updatedAt)]
        )
        return try context.fetch(descriptor)
    }

    public static func fetchRecord(id: UUID, in context: ModelContext) throws -> ApplicationRecord? {
        let descriptor = FetchDescriptor<ApplicationRecord>(
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
                ApplicationRecord(
                    id: remote.id,
                    eventID: remote.eventID,
                    repIdentityID: remote.repIdentityID,
                    repMembershipID: remote.repMembershipID,
                    roundName: remote.roundName,
                    appliedOn: remote.appliedOn,
                    resultOn: remote.resultOn,
                    statusRaw: remote.statusRaw,
                    seatRaw: remote.seatRaw,
                    ticketCount: remote.ticketCount,
                    priceYen: remote.priceYen,
                    note: remote.note,
                    updatedAt: remote.updatedAt,
                    remoteUpdatedAt: remote.updatedAt,
                    syncState: .synced,
                    deletedAt: nil
                )
            )
        }
    }
}

extension ApplicationCompanionRecord: SyncableRecord {
    public static var syncCollection: SyncCollection { .applicationCompanions }

    public var recordID: UUID { id }
    public var recordUpdatedAt: Date { updatedAt }

    public func syncPayload() -> [String: JSONValue] {
        [
            "application_id": .string(applicationID.uuidString),
            "identity_id": SyncPayloadBuilder.optionalUUID(identityID),
            "display_name": .string(displayName),
            "position": .number(Double(position)),
            "deleted_at": SyncPayloadBuilder.optionalDateTime(deletedAt),
        ]
    }

    static func parseRemote(_ object: [String: JSONValue]) -> RemoteApplicationCompanion? {
        guard let id = SyncField.uuid(object, "id"),
              let applicationID = SyncField.uuid(object, "application_id"),
              let displayName = SyncField.string(object, "display_name"),
              let updatedAt = SyncField.dateTime(object, "updated_at")
        else { return nil }

        return RemoteApplicationCompanion(
            id: id,
            applicationID: applicationID,
            identityID: SyncField.uuid(object, "identity_id"),
            displayName: displayName,
            position: SyncField.int(object, "position") ?? 0,
            updatedAt: updatedAt,
            deletedAt: SyncField.dateTime(object, "deleted_at")
        )
    }

    public static func fetchPending(in context: ModelContext) throws -> [ApplicationCompanionRecord] {
        let descriptor = FetchDescriptor<ApplicationCompanionRecord>(
            predicate: #Predicate { $0.syncStateRaw != 0 },
            sortBy: [SortDescriptor(\.updatedAt)]
        )
        return try context.fetch(descriptor)
    }

    public static func fetchRecord(id: UUID, in context: ModelContext) throws -> ApplicationCompanionRecord? {
        let descriptor = FetchDescriptor<ApplicationCompanionRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    /// 同一申込の未削除同行者。`position` 昇順（`api-contract.md` §7）。
    public static func fetchActive(applicationID: UUID, in context: ModelContext) throws -> [ApplicationCompanionRecord] {
        let descriptor = FetchDescriptor<ApplicationCompanionRecord>(
            predicate: #Predicate { $0.applicationID == applicationID && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.position)]
        )
        return try context.fetch(descriptor)
    }

    /// 削除済みも含む（全置換で id が再送されたときの復活用）。
    public static func fetchAll(applicationID: UUID, in context: ModelContext) throws -> [ApplicationCompanionRecord] {
        let descriptor = FetchDescriptor<ApplicationCompanionRecord>(
            predicate: #Predicate { $0.applicationID == applicationID },
            sortBy: [SortDescriptor(\.position)]
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
                ApplicationCompanionRecord(
                    id: remote.id,
                    applicationID: remote.applicationID,
                    identityID: remote.identityID,
                    displayName: remote.displayName,
                    position: remote.position,
                    updatedAt: remote.updatedAt,
                    remoteUpdatedAt: remote.updatedAt,
                    syncState: .synced,
                    deletedAt: nil
                )
            )
        }
    }
}
