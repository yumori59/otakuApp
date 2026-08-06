import Foundation
import SwiftData
import Domain

extension IdentityRecord {
    public static func make(from identity: Identity, syncState: SyncState = .pendingCreate) -> IdentityRecord {
        IdentityRecord(
            id: identity.id,
            displayName: identity.displayName,
            relationRaw: identity.relation.rawValue,
            colorHex: identity.colorHex,
            joinedOn: identity.joinedOn,
            note: identity.note,
            historyVisible: identity.historyVisible,
            sortOrder: identity.sortOrder,
            updatedAt: identity.updatedAt,
            syncState: syncState
        )
    }

    public func toDomain() -> Identity {
        Identity(
            id: id,
            displayName: displayName,
            relation: relation,
            colorHex: colorHex,
            joinedOn: joinedOn,
            historyVisible: historyVisible,
            note: note,
            sortOrder: sortOrder,
            updatedAt: updatedAt
        )
    }

    public func apply(patch: IdentityPatch, now: Date = Date()) {
        displayName = patch.displayName.applied(to: displayName) ?? displayName
        relation = patch.relation.applied(to: relation) ?? relation
        colorHex = patch.colorHex.applied(to: colorHex) ?? colorHex
        joinedOn = patch.joinedOn.applied(to: joinedOn)
        note = patch.note.applied(to: note) ?? ""
        historyVisible = patch.historyVisible.applied(to: historyVisible) ?? historyVisible
        sortOrder = patch.sortOrder.applied(to: sortOrder) ?? sortOrder
        markDirty(now: now)
    }

    /// pull でサーバー行を取り込む（LWW で takeRemote と決めた後）。
    public func applyRemote(
        displayName: String,
        relationRaw: String,
        colorHex: String,
        joinedOn: Date?,
        note: String,
        historyVisible: Bool,
        sortOrder: Int,
        updatedAt: Date,
        deletedAt: Date?
    ) {
        self.displayName = displayName
        self.relationRaw = relationRaw
        self.colorHex = colorHex
        self.joinedOn = joinedOn
        self.note = note
        self.historyVisible = historyVisible
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
        self.remoteUpdatedAt = updatedAt
        self.deletedAt = deletedAt
        self.syncState = .synced
    }
}
