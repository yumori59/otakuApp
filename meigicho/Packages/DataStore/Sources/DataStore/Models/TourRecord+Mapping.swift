import Foundation
import SwiftData
import Domain

extension TourRecord {
    public static func make(from tour: Tour, syncState: SyncState = .pendingCreate) -> TourRecord {
        TourRecord(
            id: tour.id,
            name: tour.name,
            artistNameRaw: tour.artistNameRaw,
            updatedAt: tour.updatedAt,
            syncState: syncState
        )
    }

    public func toDomain() -> Tour {
        Tour(id: id, name: name, artistNameRaw: artistNameRaw, updatedAt: updatedAt)
    }

    public func apply(patch: TourPatch, now: Date = Date()) {
        name = patch.name.applied(to: name) ?? name
        artistNameRaw = patch.artistNameRaw.applied(to: artistNameRaw) ?? ""
        markDirty(now: now)
    }

    func applyRemote(_ remote: RemoteTour) {
        name = remote.name
        artistNameRaw = remote.artistNameRaw
        updatedAt = remote.updatedAt
        remoteUpdatedAt = remote.updatedAt
        deletedAt = remote.deletedAt
        syncState = .synced
    }
}
