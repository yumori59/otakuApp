import Foundation
import SwiftData
import Domain

extension EventRecord {
    public static func make(from event: EventEntity, syncState: SyncState = .pendingCreate) -> EventRecord {
        EventRecord(
            id: event.id,
            tourID: event.tourID,
            name: event.name,
            venueNameRaw: event.venueNameRaw,
            eventDate: event.eventDate,
            startsAt: event.startsAt,
            updatedAt: event.updatedAt,
            syncState: syncState
        )
    }

    public func toDomain() -> EventEntity {
        EventEntity(
            id: id,
            tourID: tourID,
            name: name,
            venueNameRaw: venueNameRaw,
            eventDate: eventDate,
            startsAt: startsAt,
            updatedAt: updatedAt
        )
    }

    public func apply(patch: EventPatch, now: Date = Date()) {
        name = patch.name.applied(to: name) ?? name
        venueNameRaw = patch.venueNameRaw.applied(to: venueNameRaw) ?? ""
        eventDate = patch.eventDate.applied(to: eventDate)
        startsAt = patch.startsAt.applied(to: startsAt)
        markDirty(now: now)
    }

    func applyRemote(_ remote: RemoteEvent) {
        tourID = remote.tourID
        name = remote.name
        venueNameRaw = remote.venueNameRaw
        eventDate = remote.eventDate
        startsAt = remote.startsAt
        updatedAt = remote.updatedAt
        remoteUpdatedAt = remote.updatedAt
        deletedAt = remote.deletedAt
        syncState = .synced
    }
}
