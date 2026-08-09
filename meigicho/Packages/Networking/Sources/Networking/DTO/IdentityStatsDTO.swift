import Foundation
import Domain

struct IdentityStatsItemDTO: Decodable, Sendable {
    let identityID: UUID
    let applicationCount: Int
    let wonCount: Int
    let lostCount: Int
    let pendingCount: Int
    let winRatePercent: Double?

    enum CodingKeys: String, CodingKey {
        case identityID = "identity_id"
        case applicationCount = "application_count"
        case wonCount = "won_count"
        case lostCount = "lost_count"
        case pendingCount = "pending_count"
        case winRatePercent = "win_rate_percent"
    }

    func toDomain() -> IdentityStatsItem {
        IdentityStatsItem(
            identityID: identityID,
            applicationCount: applicationCount,
            wonCount: wonCount,
            lostCount: lostCount,
            pendingCount: pendingCount,
            winRatePercent: winRatePercent
        )
    }
}

struct IdentityStatsResponse: Decodable, Sendable {
    let items: [IdentityStatsItemDTO]

    func toDomain() -> IdentityStatsSnapshot {
        IdentityStatsSnapshot(items: items.map { $0.toDomain() })
    }
}
