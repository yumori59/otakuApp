import Foundation
import Domain

struct HomeSummaryResponse: Decodable, Sendable {
    let identityCount: Int
    let renewalsWithin30Days: Int
    let pendingResults: Int

    enum CodingKeys: String, CodingKey {
        case identityCount = "identity_count"
        case renewalsWithin30Days = "renewals_within_30_days"
        case pendingResults = "pending_results"
    }

    func toDomain() -> HomeSummary {
        HomeSummary(
            identityCount: identityCount,
            renewalsWithin30Days: renewalsWithin30Days,
            pendingResults: pendingResults
        )
    }
}
