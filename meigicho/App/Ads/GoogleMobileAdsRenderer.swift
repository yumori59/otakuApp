#if canImport(GoogleMobileAds)
import SwiftUI
import UIKit
import GoogleMobileAds
import DesignSystem

/// Google Mobile Ads SDK の実装（Stage 1: インライン・アダプティブバナーのみ）。
/// `#if canImport(GoogleMobileAds)` で SDK を封じ込める（IOS-5 / 既存パターン踏襲:
/// `App/Purchases/RevenueCatPurchasesService.swift`）。
///
/// ネイティブ広告・リワード広告は Stage 2（別タスク）で実装する。
/// 参照: `docs/plans/admob-integration/plan.md` §5 Wave2 T9 の Stage 分割方針。
final class GoogleMobileAdsRenderer: AdRenderer, @unchecked Sendable {
    private let appID: String

    /// - Parameter appID: `ADMOB_APP_ID`（`GADApplicationIdentifier`）。空文字での生成は
    ///   `AdRendererFactory` 側で弾く（`DisabledAdRenderer` を返す）ため、ここでは常に非空を仮定する。
    init(appID: String) {
        self.appID = appID
        AdsInitializer.start()
    }

    func bannerView(
        adUnitID: String,
        width: CGFloat,
        onFailure: @escaping @MainActor () -> Void
    ) -> AnyView? {
        guard !adUnitID.isEmpty, width > 0 else { return nil }
        return AnyView(BannerAdRepresentable(adUnitID: adUnitID, width: width, onFailure: onFailure))
    }

    func nativeAdView(adUnitID: String) -> AnyView? {
        // Stage 2（別タスク）で GADAdLoader + カスタムレイアウトを実装する。
        nil
    }

    func loadRewardedAd(adUnitID: String) async throws {
        // Stage 2（別タスク）で GADRewardedAd を実装する。
        throw AdRendererError.notImplemented
    }

    func presentRewardedAd() async throws -> Bool {
        throw AdRendererError.notImplemented
    }
}

/// インライン・アダプティブバナーの SwiftUI ラッパー（F2-2 / F2-4 / F2-5）。
private struct BannerAdRepresentable: UIViewRepresentable {
    let adUnitID: String
    let width: CGFloat
    /// no-fill / ロード失敗を呼び出し側（`AdSlot`）へ通知する。空枠を残さないため（F4-4 / F5-6）
    let onFailure: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> GADBannerView {
        let adSize = GADCurrentOrientationInlineAdaptiveBannerAdSizeWithWidth(width)
        let banner = GADBannerView(adSize: adSize)
        banner.adUnitID = adUnitID
        banner.rootViewController = Self.currentRootViewController()
        banner.delegate = context.coordinator
        banner.load(Self.makeRequest())
        return banner
    }

    func updateUIView(_ uiView: GADBannerView, context: Context) {}

    /// `GADBannerViewDelegate` を受ける入れ物。SDK 型は本ファイル（`#if canImport`）の外に出さない
    final class Coordinator: NSObject, GADBannerViewDelegate {
        private let onFailure: @MainActor () -> Void

        init(onFailure: @escaping @MainActor () -> Void) {
            self.onFailure = onFailure
        }

        func bannerView(_ bannerView: GADBannerView, didFailToReceiveAdWithError error: Error) {
            // SDK はデリゲートをメインスレッドで呼ぶ
            let handler = onFailure
            MainActor.assumeIsolated { handler() }
        }
    }

    private static func makeRequest() -> GADRequest {
        let request = GADRequest()
        let extras = GADExtras()
        // 非パーソナライズ広告固定（F1-4）。ATT / UMP は要求しない（docs/08 §2.8）。
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        return request
    }

    @MainActor
    private static func currentRootViewController() -> UIViewController? {
        // 既存パターン踏襲: `Packages/Network/Sources/Network/GoogleSignInService.swift` の
        // `WebAuthPresentationAnchorProvider.presentationAnchor(for:)`
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    }
}
#endif
