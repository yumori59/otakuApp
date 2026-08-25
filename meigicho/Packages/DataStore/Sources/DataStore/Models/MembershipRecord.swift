import Foundation
import SwiftData
import Domain

/// SwiftData 上の会員情報行（`docs/03` `memberships`）。
/// 会員番号は全桁を平文で保持する（2026-08-20 ユーザー判断により暗号化・下4桁保持を撤回）。
@Model
public final class MembershipRecord {
    @Attribute(.unique) public var id: UUID
    public var ownerID: UUID?
    public var identityID: UUID
    public var fanClubNameRaw: String
    public var memberNo: String?
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
        memberNo: String? = nil,
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
        self.memberNo = memberNo
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
