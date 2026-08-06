import Foundation

/// `GET /v1/home/summary` の Domain 表現。
public struct HomeSummary: Equatable, Sendable {
    public let identityCount: Int
    public let renewalsWithin30Days: Int
    public let pendingResults: Int

    public init(
        identityCount: Int,
        renewalsWithin30Days: Int,
        pendingResults: Int
    ) {
        self.identityCount = identityCount
        self.renewalsWithin30Days = renewalsWithin30Days
        self.pendingResults = pendingResults
    }
}
