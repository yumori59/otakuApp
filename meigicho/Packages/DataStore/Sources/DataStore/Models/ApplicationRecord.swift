import Foundation
import SwiftData
import Domain

/// SwiftData 上の申込行。
/// **`tour_id` は持たない**（サーバー契約上 applications は `event_id` のみ。ツアーは event から引く / F5）。
@Model
public final class ApplicationRecord {
    @Attribute(.unique) public var id: UUID
    public var ownerID: UUID?
    public var eventID: UUID
    public var repIdentityID: UUID
    public var repMembershipID: UUID?
    public var roundName: String?
    public var appliedOn: Date?
    public var resultOn: Date?
    public var statusRaw: String
    public var seatRaw: String
    public var ticketCount: Int
    public var priceYen: Int?
    public var note: String
    public var updatedAt: Date
    public var remoteUpdatedAt: Date?
    public var syncStateRaw: Int
    public var deletedAt: Date?

    public init(
        id: UUID,
        ownerID: UUID? = nil,
        eventID: UUID,
        repIdentityID: UUID,
        repMembershipID: UUID? = nil,
        roundName: String? = nil,
        appliedOn: Date? = nil,
        resultOn: Date? = nil,
        statusRaw: String = ApplicationStatus.applied.rawValue,
        seatRaw: String = "",
        ticketCount: Int = 1,
        priceYen: Int? = nil,
        note: String = "",
        updatedAt: Date = Date(),
        remoteUpdatedAt: Date? = nil,
        syncState: SyncState = .pendingCreate,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.eventID = eventID
        self.repIdentityID = repIdentityID
        self.repMembershipID = repMembershipID
        self.roundName = roundName
        self.appliedOn = appliedOn
        self.resultOn = resultOn
        self.statusRaw = statusRaw
        self.seatRaw = seatRaw
        self.ticketCount = ticketCount
        self.priceYen = priceYen
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

    /// 未知の生値は `.applied` へ寄せる（`ApplicationStatus.decoded` と同じ規則 / E-12）。
    public var status: ApplicationStatus {
        get { ApplicationStatus.decoded(statusRaw).value }
        set { statusRaw = newValue.rawValue }
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

/// SwiftData 上の同行者行。1 申込につき最大 `ApplicationCompanionRecord.maxPerApplication` 件（`api-contract.md` §7）。
@Model
public final class ApplicationCompanionRecord {
    public static let maxPerApplication = 3

    @Attribute(.unique) public var id: UUID
    public var ownerID: UUID?
    public var applicationID: UUID
    public var identityID: UUID?
    public var displayName: String
    public var position: Int
    public var updatedAt: Date
    public var remoteUpdatedAt: Date?
    public var syncStateRaw: Int
    public var deletedAt: Date?

    public init(
        id: UUID,
        ownerID: UUID? = nil,
        applicationID: UUID,
        identityID: UUID? = nil,
        displayName: String,
        position: Int = 0,
        updatedAt: Date = Date(),
        remoteUpdatedAt: Date? = nil,
        syncState: SyncState = .pendingCreate,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.applicationID = applicationID
        self.identityID = identityID
        self.displayName = displayName
        self.position = position
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
