import Foundation

/// `GET /v1/stats/identities` の 1 名義分（`docs/04` §3.5）。
public struct IdentityStatsItem: Equatable, Sendable {
    public let identityID: UUID
    public let applicationCount: Int
    public let wonCount: Int
    public let lostCount: Int
    public let pendingCount: Int
    /// `won+lost == 0` のとき `nil`。小数 1 桁。
    public let winRatePercent: Double?

    public init(
        identityID: UUID,
        applicationCount: Int,
        wonCount: Int,
        lostCount: Int,
        pendingCount: Int,
        winRatePercent: Double?
    ) {
        self.identityID = identityID
        self.applicationCount = applicationCount
        self.wonCount = wonCount
        self.lostCount = lostCount
        self.pendingCount = pendingCount
        self.winRatePercent = winRatePercent
    }
}

/// 名義別統計のスナップショット。
public struct IdentityStatsSnapshot: Equatable, Sendable {
    public let items: [IdentityStatsItem]

    public init(items: [IdentityStatsItem]) {
        self.items = items
    }

    public func item(for identityID: UUID) -> IdentityStatsItem? {
        items.first { $0.identityID == identityID }
    }

    public func winCounts() -> [UUID: Int] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.identityID, $0.wonCount) })
    }
}
