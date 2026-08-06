import Foundation
import Domain

/// RevenueCat 未設定時のスタブ。ペイウォール UI は表示するが購入は不可。
struct DisabledPurchasesService: PurchasesProviding, Sendable {
    var isConfigured: Bool { false }

    func configure(userID: UUID) async throws {}

    func fetchOfferings() async throws -> [SubscriptionOffering] {
        SubscriptionOffering.fallbackOfferings
    }

    func purchase(plan: SubscriptionPlan) async throws -> Entitlement {
        throw AppError.unknown(
            code: "PURCHASES_NOT_CONFIGURED",
            message: "課金機能は準備中です。RevenueCat API キーを設定してください。"
        )
    }

    func restorePurchases() async throws -> Entitlement? {
        throw AppError.unknown(
            code: "PURCHASES_NOT_CONFIGURED",
            message: "課金機能は準備中です。RevenueCat API キーを設定してください。"
        )
    }
}
