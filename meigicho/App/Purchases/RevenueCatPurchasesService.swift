#if canImport(RevenueCat)
import Foundation
import Domain
import RevenueCat

/// RevenueCat SDK ラッパー（`docs/07` §9）。
///
/// 課金機能は現在無効化中（`project.yml` から RevenueCat パッケージ依存を外している）。
/// 理由: 自作の `Network` パッケージ名と Apple 標準の `Network.framework`（RevenueCat が依存）が
/// 衝突し、クリーンビルドで失敗するため（アカウント削除機能レビュー時に発覚）。
/// 再有効化する場合は `project.yml` に RevenueCat パッケージ依存を戻すこと（このファイルの実装はそのまま使える）。
final class RevenueCatPurchasesService: PurchasesProviding, @unchecked Sendable {
    private let apiKey: String
    private let entitlementID = "plus"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    var isConfigured: Bool { !apiKey.isEmpty }

    func configure(userID: UUID) async throws {
        guard isConfigured else { return }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: apiKey, appUserID: userID.uuidString.lowercased())
    }

    func fetchOfferings() async throws -> [SubscriptionOffering] {
        let offerings = try await Purchases.shared.offerings()
        guard let current = offerings.current else {
            return SubscriptionOffering.fallbackOfferings
        }
        var result: [SubscriptionOffering] = []
        if let annual = current.annual {
            result.append(SubscriptionOffering(
                plan: .annual,
                priceText: annual.storeProduct.localizedPriceString + " / 年",
                subtitle: "月あたり¥233"
            ))
        }
        if let monthly = current.monthly {
            result.append(SubscriptionOffering(
                plan: .monthly,
                priceText: monthly.storeProduct.localizedPriceString + " / 月"
            ))
        }
        return result.isEmpty ? SubscriptionOffering.fallbackOfferings : result
    }

    func purchase(plan: SubscriptionPlan) async throws -> Entitlement {
        let offerings = try await Purchases.shared.offerings()
        guard let current = offerings.current else {
            throw AppError.unknown(code: "OFFERING_UNAVAILABLE", message: "プランを取得できませんでした")
        }
        let package: Package? = switch plan {
        case .annual: current.annual
        case .monthly: current.monthly
        }
        guard let package else {
            throw AppError.unknown(code: "PACKAGE_UNAVAILABLE", message: "選択したプランがありません")
        }
        let result = try await Purchases.shared.purchase(package: package)
        if result.userCancelled {
            throw AppError.unknown(code: "PURCHASE_CANCELLED", message: nil)
        }
        return mapEntitlement(from: result.customerInfo)
    }

    func restorePurchases() async throws -> Entitlement? {
        let info = try await Purchases.shared.restorePurchases()
        let mapped = mapEntitlement(from: info)
        return mapped.plan == .plus ? mapped : nil
    }

    private func mapEntitlement(from info: CustomerInfo) -> Entitlement {
        let plus = info.entitlements[entitlementID]
        let isActive = plus?.isActive == true
        return Entitlement(
            plan: isActive ? .plus : .free,
            expiresAt: plus?.expirationDate,
            inGracePeriod: plus?.billingIssueDetectedAt != nil,
            identityLimit: isActive ? nil : 3,
            shareLimit: isActive ? nil : 1
        )
    }
}
#endif
