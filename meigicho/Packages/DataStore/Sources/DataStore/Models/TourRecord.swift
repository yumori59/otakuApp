import Foundation
import SwiftData
import Domain

/// SwiftData 上のツアー行。
/// 新規作成は申込の find-or-create 経由のみ（`POST /v1/tours` は存在しない = C3）だが、
/// 同期上は他コレクションと同じ upsert + LWW で扱う（`docs/04` §4）。
@Model
public final class TourRecord {
    @Attribute(.unique) public var id: UUID
    public var ownerID: UUID?
    public var name: String
    public var artistNameRaw: String
    public var updatedAt: Date
    public var remoteUpdatedAt: Date?
    public var syncStateRaw: Int
    public var deletedAt: Date?

    public init(
        id: UUID,
        ownerID: UUID? = nil,
        name: String,
        artistNameRaw: String = "",
        updatedAt: Date = Date(),
        remoteUpdatedAt: Date? = nil,
        syncState: SyncState = .pendingCreate,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.name = name
        self.artistNameRaw = artistNameRaw
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
