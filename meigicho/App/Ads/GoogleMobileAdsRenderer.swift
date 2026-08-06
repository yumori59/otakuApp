#if canImport(GoogleMobileAds)
import SwiftUI
import UIKit
import GoogleMobileAds

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

    func bannerView(adUnitID: String, width: CGFloat) -> AnyView? {
        guard !adUnitID.isEmpty, width > 0 else { return nil }
        return AnyView(BannerAdRepresentable(adUnitID: adUnitID, width: width))
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

    func makeUIView(context: Context) -> GADBannerView {
        let adSize = GADCurrentOrientationInlineAdaptiveBannerAdSizeWithWidth(width)
        let banner = GADBannerView(adSize: adSize)
        banner.adUnitID = adUnitID
        banner.rootViewController = Self.currentRootViewController()
        banner.load(Self.makeRequest())
        return banner
    }

    func updateUIView(_ uiView: GADBannerView, context: Context) {}

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
