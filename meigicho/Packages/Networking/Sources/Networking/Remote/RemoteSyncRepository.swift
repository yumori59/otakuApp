import Foundation
import Domain
import Core

/// `SyncRepository` の HTTP 実装（`POST /v1/sync/pull` / `push`）。
public struct RemoteSyncRepository: SyncRepository {
    private let client: ApiClient
    private let encoder = JSONEncoder()

    public init(client: ApiClient) {
        self.client = client
    }

    public func pull(_ request: SyncPullRequest) async throws -> SyncPullResult {
        let body = SyncPullRequestBody(
            cursor: request.cursor.map(APIDateFormat.dateTimeString),
            collections: request.collections.map(\.rawValue)
        )
        let data = try encoder.encode(body)
        return try await client.send(
            .versioned(.post, "/sync/pull", body: data),
            as: SyncPullResponseDTO.self
        ).toDomain()
    }

    public func push(mutations: [SyncMutation]) async throws -> SyncPushResult {
        let body = SyncPushRequestBody(
            mutations: mutations.map {
                SyncMutationBody(
                    collection: $0.collection.rawValue,
                    op: "upsert",
                    id: $0.id,
                    updatedAt: APIDateFormat.dateTimeString(from: $0.updatedAt),
                    payload: $0.payload
                )
            }
        )
        let data = try encoder.encode(body)
        return try await client.send(
            .versioned(.post, "/sync/push", body: data),
            as: SyncPushResponseDTO.self
        ).toDomain()
    }
}
