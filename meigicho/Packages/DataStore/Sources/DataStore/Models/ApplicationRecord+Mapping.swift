import Foundation
import SwiftData
import Domain

extension ApplicationRecord {
    public static func make(from draft: ApplicationDraft, eventID: UUID, now: Date = Date()) -> ApplicationRecord {
        ApplicationRecord(
            id: draft.id,
            eventID: eventID,
            repIdentityID: draft.repIdentityID,
            repMembershipID: draft.repMembershipID,
            roundName: draft.roundName,
            appliedOn: draft.appliedOn,
            resultOn: draft.resultOn,
            statusRaw: draft.status.rawValue,
            seatRaw: draft.seatRaw,
            ticketCount: draft.ticketCount,
            priceYen: draft.priceYen,
            note: draft.note,
            updatedAt: now,
            syncState: .pendingCreate
        )
    }

    /// `tourID` は event から、`companions` は別テーブルから渡す（この行自身は持たない）。
    public func toDomain(tourID: UUID, companions: [Companion]) -> ApplicationEntry {
        ApplicationEntry(
            id: id,
            tourID: tourID,
            eventID: eventID,
            repIdentityID: repIdentityID,
            repMembershipID: repMembershipID,
            roundName: roundName,
            appliedOn: appliedOn,
            resultOn: resultOn,
            status: status,
            seatRaw: seatRaw,
            ticketCount: ticketCount,
            priceYen: priceYen,
            companions: companions,
            note: note,
            updatedAt: updatedAt
        )
    }

    /// companions は全置換なのでここでは触らない（`SwiftDataApplicationRepository` の責務 / FR-AP-8）。
    public func apply(patch: ApplicationPatch, now: Date = Date()) {
        repIdentityID = patch.repIdentityID.applied(to: repIdentityID) ?? repIdentityID
        repMembershipID = patch.repMembershipID.applied(to: repMembershipID)
        roundName = patch.roundName.applied(to: roundName)
        appliedOn = patch.appliedOn.applied(to: appliedOn)
        resultOn = patch.resultOn.applied(to: resultOn)
        status = patch.status.applied(to: status) ?? status
        seatRaw = patch.seatRaw.applied(to: seatRaw) ?? ""
        ticketCount = patch.ticketCount.applied(to: ticketCount) ?? ticketCount
        priceYen = patch.priceYen.applied(to: priceYen)
        note = patch.note.applied(to: note) ?? ""
        markDirty(now: now)
    }

    func applyRemote(_ remote: RemoteApplication) {
        eventID = remote.eventID
        repIdentityID = remote.repIdentityID
        repMembershipID = remote.repMembershipID
        roundName = remote.roundName
        appliedOn = remote.appliedOn
        resultOn = remote.resultOn
        statusRaw = remote.statusRaw
        seatRaw = remote.seatRaw
        ticketCount = remote.ticketCount
        priceYen = remote.priceYen
        note = remote.note
        updatedAt = remote.updatedAt
        remoteUpdatedAt = remote.updatedAt
        deletedAt = remote.deletedAt
        syncState = .synced
    }
}

extension ApplicationCompanionRecord {
    public static func make(from companion: Companion, applicationID: UUID, now: Date = Date()) -> ApplicationCompanionRecord {
        ApplicationCompanionRecord(
            id: companion.id,
            applicationID: applicationID,
            identityID: companion.identityID,
            displayName: companion.displayName,
            position: companion.position,
            updatedAt: now,
            syncState: .pendingCreate
        )
    }

    public func toDomain() -> Companion {
        Companion(id: id, identityID: identityID, displayName: displayName, position: position)
    }

    /// 全置換更新で既存 id が再送された場合（`deletedAt` の復活も含む / `applications.service.ts` 同等）。
    public func apply(companion: Companion, now: Date = Date()) {
        identityID = companion.identityID
        displayName = companion.displayName
        position = companion.position
        deletedAt = nil
        updatedAt = now
        // 復活（pendingDelete → 再送）でも送信対象に戻す。
        if syncState != .pendingCreate {
            syncState = .pendingUpdate
        }
    }

    func applyRemote(_ remote: RemoteApplicationCompanion) {
        applicationID = remote.applicationID
        identityID = remote.identityID
        displayName = remote.displayName
        position = remote.position
        updatedAt = remote.updatedAt
        remoteUpdatedAt = remote.updatedAt
        deletedAt = remote.deletedAt
        syncState = .synced
    }
}
