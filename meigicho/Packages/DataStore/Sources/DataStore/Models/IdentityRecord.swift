import Foundation
import SwiftData
import Domain

/// SwiftData 上の名義行。Domain の値型 `Identity` とは別型（`docs/05` §2.1 / IOS-5）。
@Model
public final class IdentityRecord {
    @Attribute(.unique) public var id: UUID
    public var ownerID: UUID?
    public var displayName: String
    public var relationRaw: String
    public var colorHex: String
    public var joinedOn: Date?
    public var note: String
    public var historyVisible: Bool
    public var sortOrder: Int
    public var updatedAt: Date
    public var remoteUpdatedAt: Date?
    public var syncStateRaw: Int
    public var deletedAt: Date?

    public init(
        id: UUID,
        ownerID: UUID? = nil,
        displayName: String,
        relationRaw: String,
        colorHex: String,
        joinedOn: Date? = nil,
        note: String = "",
        historyVisible: Bool = false,
        sortOrder: Int = 0,
        updatedAt: Date = Date(),
        remoteUpdatedAt: Date? = nil,
        syncState: SyncState = .pendingCreate,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.displayName = displayName
        self.relationRaw = relationRaw
        self.colorHex = colorHex
        self.joinedOn = joinedOn
        self.note = note
        self.historyVisible = historyVisible
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.syncStateRaw = syncState.rawValue
        self.deletedAt = deletedAt
    }

    public var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .synced }
        set { syncStateRaw = newValue.rawValue }
    }

    public var relation: Relation {
        get { Relation(rawValue: relationRaw) ?? .other }
        set { relationRaw = newValue.rawValue }
    }

    /// ローカル編集の記録。`updatedAt` を進めることが LWW の前提（`docs/05`）。
    public func markDirty(now: Date = Date()) {
        updatedAt = now
        if syncState == .synced {
            syncState = .pendingUpdate
        }
    }

    public func softDelete(now: Date = Date()) {
        deletedAt = now
        updatedAt = now
        syncState = .pendingDelete
    }
}
