import Foundation
import Domain

/// `HomeRepository` の HTTP 実装（`GET /v1/home/summary`）。
public struct RemoteHomeRepository: HomeRepository {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    public func fetchSummary() async throws -> HomeSummary {
        try await client.send(
            .versioned(.get, "/home/summary"),
            as: HomeSummaryResponse.self
        ).toDomain()
    }
}
