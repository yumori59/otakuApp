import Foundation

/// ペイウォール表示のきっかけ（`docs/07` §6）。
public enum PaywallTrigger: String, Hashable, Sendable {
    case identityLimit
    case shareLinkLimit
    case settings
}

public enum SubscriptionPlan: String, Sendable, CaseIterable {
    case monthly
    case annual
}

/// 表示用のプラン情報（StoreKit / RevenueCat から取得、またはフォールバック）。
public struct SubscriptionOffering: Equatable, Sendable {
    public let plan: SubscriptionPlan
    public let priceText: String
    public let subtitle: String?

    public init(plan: SubscriptionPlan, priceText: String, subtitle: String? = nil) {
        self.plan = plan
        self.priceText = priceText
        self.subtitle = subtitle
    }

    public static let fallbackOfferings: [SubscriptionOffering] = [
        SubscriptionOffering(
            plan: .annual,
            priceText: "¥2,800 / 年",
            subtitle: "月あたり¥233"
        ),
        SubscriptionOffering(plan: .monthly, priceText: "¥350 / 月"),
    ]
}

/// RevenueCat / StoreKit の抽象（Features は SDK を知らない）。
public protocol PurchasesProviding: Sendable {
    var isConfigured: Bool { get }
    func configure(userID: UUID) async throws
    func fetchOfferings() async throws -> [SubscriptionOffering]
    /// 成功時は楽観的更新用の `Entitlement` を返す。
    func purchase(plan: SubscriptionPlan) async throws -> Entitlement
    func restorePurchases() async throws -> Entitlement?
}
