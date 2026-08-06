import Foundation
import SwiftData
import Domain

/// 送信キューのポインタ行（`docs/05` §5）。ペイロードは持たず、`IdentityRecord` 等の現在値を読む。
@Model
public final class OutboxEntry {
    @Attribute(.unique) public var id: UUID
    public var collectionRaw: String
    public var targetID: UUID
    public var enqueuedAt: Date
    public var attemptCount: Int
    public var nextRetryAt: Date?
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        collection: SyncCollection,
        targetID: UUID,
        enqueuedAt: Date = Date(),
        attemptCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.collectionRaw = collection.rawValue
        self.targetID = targetID
        self.enqueuedAt = enqueuedAt
        self.attemptCount = attemptCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
    }

    public var collection: SyncCollection? {
        SyncCollection(rawValue: collectionRaw)
    }
}
