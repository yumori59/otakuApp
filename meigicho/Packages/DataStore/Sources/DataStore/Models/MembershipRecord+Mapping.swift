import Foundation
import SwiftData
import Domain

extension MembershipRecord {
    public static func make(from membership: Membership, syncState: SyncState = .pendingCreate, now: Date = Date()) -> MembershipRecord {
        MembershipRecord(
            id: membership.id,
            identityID: membership.identityID,
            fanClubNameRaw: membership.fanClubNameRaw,
            memberNo: membership.memberNo,
            rank: membership.rank,
            renewalOn: membership.renewalOn,
            feeYen: membership.feeYen,
            autoRenew: membership.autoRenew,
            note: membership.note,
            updatedAt: now,
            syncState: syncState
        )
    }

    public func toDomain() -> Membership {
        Membership(
            id: id,
            identityID: identityID,
            fanClubNameRaw: fanClubNameRaw,
            memberNo: memberNo,
            rank: rank,
            renewalOn: renewalOn,
            feeYen: feeYen,
            autoRenew: autoRenew,
            note: note
        )
    }

    public func apply(patch: MembershipPatch, now: Date = Date()) {
        identityID = patch.identityID.applied(to: identityID) ?? identityID
        fanClubNameRaw = patch.fanClubNameRaw.applied(to: fanClubNameRaw) ?? fanClubNameRaw
        memberNo = patch.memberNo.applied(to: memberNo)
        rank = patch.rank.applied(to: rank)
        renewalOn = patch.renewalOn.applied(to: renewalOn)
        feeYen = patch.feeYen.applied(to: feeYen)
        autoRenew = patch.autoRenew.applied(to: autoRenew) ?? autoRenew
        note = patch.note.applied(to: note) ?? ""
        markDirty(now: now)
    }

    func applyRemote(_ remote: RemoteMembership) {
        identityID = remote.identityID
        fanClubNameRaw = remote.fanClubNameRaw
        memberNo = remote.memberNo
        rank = remote.rank
        renewalOn = remote.renewalOn
        feeYen = remote.feeYen
        autoRenew = remote.autoRenew
        note = remote.note
        updatedAt = remote.updatedAt
        remoteUpdatedAt = remote.updatedAt
        deletedAt = remote.deletedAt
        syncState = .synced
    }
}
