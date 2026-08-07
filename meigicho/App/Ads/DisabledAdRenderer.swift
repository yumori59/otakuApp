import SwiftUI
import DesignSystem

/// 広告ユニット ID（`ADMOB_APP_ID`）が未設定のときの no-op フォールバック（F1-6 / N6 / AC-AD-36）。
/// SDK を初期化せず、広告枠を一切描画しない。既存パターン踏襲: `DisabledPurchasesService`
/// （`App/Purchases/DisabledPurchasesService.swift`）。
struct DisabledAdRenderer: AdRenderer {
    func bannerView(
        adUnitID: String,
        width: CGFloat,
        onFailure: @escaping @MainActor () -> Void
    ) -> AnyView? { nil }

    func nativeAdView(
        adUnitID: String,
        onFailure: @escaping @MainActor () -> Void,
        onHeightChange: @escaping @MainActor (CGFloat) -> Void
    ) -> AnyView? { nil }

    func loadRewardedAd(adUnitID: String) async throws {
        throw AdRendererError.notImplemented
    }

    func presentRewardedAd() async throws -> Bool {
        throw AdRendererError.notImplemented
    }
}
