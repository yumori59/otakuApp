import Foundation
import Domain
import Core

struct SyncPullRequestBody: Encodable {
    let cursor: String?
    let collections: [String]
}

struct SyncPullResponseDTO: Decodable {
    let changes: [String: [JSONValue]]
    let nextCursor: String?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case changes
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    func toDomain() -> SyncPullResult {
        var mapped: [SyncCollection: [[String: JSONValue]]] = [:]
        for (key, rows) in changes {
            guard let collection = SyncCollection(rawValue: key) else { continue }
            mapped[collection] = rows.compactMap(\.objectValue)
        }
        let cursor = nextCursor.flatMap(APIDateFormat.dateTime)
        return SyncPullResult(changes: mapped, nextCursor: cursor, hasMore: hasMore)
    }
}

struct SyncMutationBody: Encodable {
    let collection: String
    let op: String
    let id: UUID
    let updatedAt: String
    let payload: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case collection, op, id, payload
        case updatedAt = "updated_at"
    }
}

struct SyncPushRequestBody: Encodable {
    let mutations: [SyncMutationBody]
}

struct SyncPushRejectionDTO: Decodable {
    let id: UUID
    let code: String
    let message: String
}

struct SyncPushResponseDTO: Decodable {
    let accepted: [UUID]
    let rejected: [SyncPushRejectionDTO]
    let serverTime: String

    enum CodingKeys: String, CodingKey {
        case accepted, rejected
        case serverTime = "server_time"
    }

    func toDomain() -> SyncPushResult {
        let time = APIDateFormat.dateTime(from: serverTime) ?? Date()
        return SyncPushResult(
            accepted: accepted,
            rejected: rejected.map {
                SyncPushRejection(id: $0.id, code: $0.code, message: $0.message)
            },
            serverTime: time
        )
    }
}
