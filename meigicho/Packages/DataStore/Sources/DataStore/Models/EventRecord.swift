import Foundation
import SwiftData
import Domain

/// SwiftData 上の公演行。`eventDate`（date-only）と `startsAt`（datetime）は別物（E-8）。
@Model
public final class EventRecord {
    @Attribute(.unique) public var id: UUID
    public var ownerID: UUID?
    public var tourID: UUID
    public var name: String
    public var venueNameRaw: String
    public var eventDate: Date?
    public var startsAt: Date?
    public var updatedAt: Date
    public var remoteUpdatedAt: Date?
    public var syncStateRaw: Int
    public var deletedAt: Date?

    public init(
        id: UUID,
        ownerID: UUID? = nil,
        tourID: UUID,
        name: String,
        venueNameRaw: String = "",
        eventDate: Date? = nil,
        startsAt: Date? = nil,
        updatedAt: Date = Date(),
        remoteUpdatedAt: Date? = nil,
        syncState: SyncState = .pendingCreate,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.tourID = tourID
        self.name = name
        self.venueNameRaw = venueNameRaw
        self.eventDate = eventDate
        self.startsAt = startsAt
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
