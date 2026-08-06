import Foundation
import Core

/// 課金操作のオーケストレーション。RevenueCat SDK は App 層に閉じる。
@MainActor
@Observable
public final class PurchasesStore {
    public private(set) var offerings: [SubscriptionOffering] = SubscriptionOffering.fallbackOfferings
    public private(set) var isBusy = false
    public var statusMessage: String?
    public var errorMessage: String?

    private let service: any PurchasesProviding
    private var configuredUserID: UUID?

    public init(service: any PurchasesProviding) {
        self.service = service
    }

    public var isStoreConfigured: Bool { service.isConfigured }

    /// ログイン後に RevenueCat をユーザー ID で紐付ける。
    public func configureIfNeeded(userID: UUID) async {
        guard configuredUserID != userID else { return }
        do {
            try await service.configure(userID: userID)
            configuredUserID = userID
            await reloadOfferings()
        } catch {
            errorMessage = Self.message(from: error)
        }
    }

    public func reloadOfferings() async {
        guard service.isConfigured else { return }
        do {
            offerings = try await service.fetchOfferings()
        } catch {
            // 価格取得失敗時はフォールバック表示のまま
            errorMessage = Self.message(from: error)
        }
    }

    @discardableResult
    public func purchase(plan: SubscriptionPlan, profile: ProfileStore) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        statusMessage = nil
        do {
            let entitlement = try await service.purchase(plan: plan)
            profile.applyEntitlement(entitlement)
            statusMessage = plan == .annual
                ? "Plus（年額プラン）が有効になりました"
                : "Plus（月額プラン）が有効になりました"
            // Webhook 未到着でも Plus を落とさない（`docs/07` §9.2）。merge でボーナス枠だけ取り込む。
            await profile.load()
            return true
        } catch {
            if Self.isPurchaseCancelled(error) { return false }
            errorMessage = Self.message(from: error)
            return false
        }
    }

    @discardableResult
    public func restore(profile: ProfileStore) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        statusMessage = nil
        do {
            if let entitlement = try await service.restorePurchases() {
                profile.applyEntitlement(entitlement)
                statusMessage = "購入を復元しました: Plus が有効です"
                await profile.load()
                return true
            }
            statusMessage = "復元できる購入が見つかりませんでした"
            return false
        } catch {
            if Self.isPurchaseCancelled(error) { return false }
            errorMessage = Self.message(from: error)
            return false
        }
    }

    public func clearMessages() {
        statusMessage = nil
        errorMessage = nil
    }

    public func resetSession() {
        configuredUserID = nil
        clearMessages()
    }

    private static func isPurchaseCancelled(_ error: Error) -> Bool {
        guard let appError = error as? AppError,
              case .unknown(let code, _) = appError
        else { return false }
        return code == "PURCHASE_CANCELLED"
    }

    private static func message(from error: Error) -> String {
        if let appError = error as? AppError {
            // クライアント生成の unknown は message を優先（DisabledPurchases の準備中文言など）
            if case .unknown(_, let message) = appError, let message, !message.isEmpty {
                return message
            }
            return appError.userMessage
        }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError).userMessage }
        return "購入処理に失敗しました"
    }
}
