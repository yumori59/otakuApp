import Foundation
import SwiftData
import Domain

/// SwiftData 上の会員情報行（`docs/03` `memberships`）。
/// **会員番号は下 4 桁のみ**を保持する（Q8 / C5）。
@Model
public final class MembershipRecord {
    @Attribute(.unique) public var id: UUID
    public var ownerID: UUID?
    public var identityID: UUID
    public var fanClubNameRaw: String
    public var memberNoLast4: String?
    public var rank: String?
    public var renewalOn: Date?
    public var feeYen: Int?
    public var autoRenew: Bool
    public var note: String
    public var updatedAt: Date
    public var remoteUpdatedAt: Date?
    public var syncStateRaw: Int
    public var deletedAt: Date?

    public init(
        id: UUID,
        ownerID: UUID? = nil,
        identityID: UUID,
        fanClubNameRaw: String,
        memberNoLast4: String? = nil,
        rank: String? = nil,
        renewalOn: Date? = nil,
        feeYen: Int? = nil,
        autoRenew: Bool = false,
        note: String = "",
        updatedAt: Date = Date(),
        remoteUpdatedAt: Date? = nil,
        syncState: SyncState = .pendingCreate,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.identityID = identityID
        self.fanClubNameRaw = fanClubNameRaw
        self.memberNoLast4 = memberNoLast4
        self.rank = rank
        self.renewalOn = renewalOn
        self.feeYen = feeYen
        self.autoRenew = autoRenew
        self.note = note
        self.updatedAt = updatedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.syncStateRaw = syncState.rawValue
        self.deletedAt = deletedAt
    }

    public var syncState: SyncState {
        get { SyncState(rawValue: syncStateRaw) ?? .synced }
        set { syncStateRaw = newValue.rawValue }
    }

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
