import Foundation

/// `docs/04` §4 の同期コレクション。
public enum SyncCollection: String, CaseIterable, Codable, Sendable {
    case identities
    case memberships
    case tours
    case events
    case applications
    case applicationCompanions = "application_companions"
}

public struct SyncPullRequest: Equatable, Sendable {
    public var cursor: Date?
    public var collections: [SyncCollection]

    public init(cursor: Date? = nil, collections: [SyncCollection] = SyncCollection.allCases) {
        self.cursor = cursor
        self.collections = collections
    }
}

public struct SyncPullResult: Equatable, Sendable {
    /// コレクション名 → レコード（snake_case JSON オブジェクト）
    public var changes: [SyncCollection: [[String: JSONValue]]]
    public var nextCursor: Date?
    public var hasMore: Bool

    public init(
        changes: [SyncCollection: [[String: JSONValue]]] = [:],
        nextCursor: Date? = nil,
        hasMore: Bool = false
    ) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct SyncMutation: Equatable, Sendable {
    public var collection: SyncCollection
    public var id: UUID
    public var updatedAt: Date
    public var payload: [String: JSONValue]

    public init(
        collection: SyncCollection,
        id: UUID,
        updatedAt: Date,
        payload: [String: JSONValue]
    ) {
        self.collection = collection
        self.id = id
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

public struct SyncPushRejection: Equatable, Sendable {
    public var id: UUID
    public var code: String
    public var message: String

    public init(id: UUID, code: String, message: String) {
        self.id = id
        self.code = code
        self.message = message
    }
}

public struct SyncPushResult: Equatable, Sendable {
    public var accepted: [UUID]
    public var rejected: [SyncPushRejection]
    public var serverTime: Date

    public init(accepted: [UUID], rejected: [SyncPushRejection], serverTime: Date) {
        self.accepted = accepted
        self.rejected = rejected
        self.serverTime = serverTime
    }
}
