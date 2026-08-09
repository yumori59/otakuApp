import Foundation
import Domain

/// `StatsRepository` の HTTP 実装（`GET /v1/stats/identities`）。
public struct RemoteStatsRepository: StatsRepository {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    public func fetchIdentityStats() async throws -> IdentityStatsSnapshot {
        try await client.send(
            .versioned(.get, "/stats/identities"),
            as: IdentityStatsResponse.self
        ).toDomain()
    }
}
