import Foundation
import SwiftData
import Domain
import Core

/// pull 1 行（`apps/api/src/sync/sync-serialize.ts` の `memberships`）。
struct RemoteMembership {
    var id: UUID
    var identityID: UUID
    var fanClubNameRaw: String
    var memberNoLast4: String?
    var rank: String?
    var renewalOn: Date?
    var feeYen: Int?
    var autoRenew: Bool
    var note: String
    var updatedAt: Date
    var deletedAt: Date?
}

extension MembershipRecord: SyncableRecord {
    public static var syncCollection: SyncCollection { .memberships }

    public var recordID: UUID { id }
    public var recordUpdatedAt: Date { updatedAt }

    /// `POST /v1/sync/push` 用の snake_case payload。
    public func syncPayload() -> [String: JSONValue] {
        [
            "identity_id": .string(identityID.uuidString),
            "fan_club_name_raw": .string(fanClubNameRaw),
            "member_no_last4": SyncPayloadBuilder.optionalString(memberNoLast4),
            "rank": SyncPayloadBuilder.optionalString(rank),
            "renewal_on": SyncPayloadBuilder.optionalDateOnly(renewalOn),
            "fee_yen": SyncPayloadBuilder.optionalInt(feeYen),
            "auto_renew": .bool(autoRenew),
            "note": SyncPayloadBuilder.optionalString(note),
            "deleted_at": SyncPayloadBuilder.optionalDateTime(deletedAt),
        ]
    }

    static func parseRemote(_ object: [String: JSONValue]) -> RemoteMembership? {
        guard let id = SyncField.uuid(object, "id"),
              let identityID = SyncField.uuid(object, "identity_id"),
              let fanClubNameRaw = SyncField.string(object, "fan_club_name_raw"),
              let updatedAt = SyncField.dateTime(object, "updated_at")
        else { return nil }

        return RemoteMembership(
            id: id,
            identityID: identityID,
            fanClubNameRaw: fanClubNameRaw,
            memberNoLast4: SyncField.string(object, "member_no_last4"),
            rank: SyncField.string(object, "rank"),
            renewalOn: SyncField.dateOnly(object, "renewal_on"),
            feeYen: SyncField.int(object, "fee_yen"),
            autoRenew: SyncField.bool(object, "auto_renew"),
            note: SyncField.text(object, "note"),
            updatedAt: updatedAt,
            deletedAt: SyncField.dateTime(object, "deleted_at")
        )
    }

    public static func fetchPending(in context: ModelContext) throws -> [MembershipRecord] {
        let descriptor = FetchDescriptor<MembershipRecord>(
            predicate: #Predicate { $0.syncStateRaw != 0 },
            sortBy: [SortDescriptor(\.updatedAt)]
        )
        return try context.fetch(descriptor)
    }

    public static func fetchRecord(id: UUID, in context: ModelContext) throws -> MembershipRecord? {
        let descriptor = FetchDescriptor<MembershipRecord>(
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
                MembershipRecord(
                    id: remote.id,
                    identityID: remote.identityID,
                    fanClubNameRaw: remote.fanClubNameRaw,
                    memberNoLast4: remote.memberNoLast4,
                    rank: remote.rank,
                    renewalOn: remote.renewalOn,
                    feeYen: remote.feeYen,
                    autoRenew: remote.autoRenew,
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
