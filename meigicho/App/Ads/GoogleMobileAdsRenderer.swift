#if canImport(GoogleMobileAds)
import SwiftUI
import UIKit
import GoogleMobileAds
import DesignSystem

/// Google Mobile Ads SDK の実装（Stage 1: バナー / Stage 2: ネイティブ）。
/// `#if canImport(GoogleMobileAds)` で SDK を封じ込める（IOS-5 / 既存パターン踏襲:
/// `App/Purchases/RevenueCatPurchasesService.swift`）。
///
/// リワード広告は Stage 2 の別タスクで実装する。
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

    func nativeAdView(
        adUnitID: String,
        onFailure: @escaping @MainActor () -> Void
    ) -> AnyView? {
        guard !adUnitID.isEmpty else { return nil }
        return AnyView(NativeAdRepresentable(adUnitID: adUnitID, onFailure: onFailure))
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
        banner.rootViewController = AdRequestFactory.currentRootViewController()
        banner.delegate = context.coordinator
        banner.load(AdRequestFactory.makeRequest())
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
}

/// ネイティブ広告（小）の SwiftUI ラッパー（F2-1 / F2-3）。
///
/// `GADNativeAdView` をコンテナにし、内側に `DesignSystem.AdNativeCard`（カスタムレイアウト、
/// AdMob 標準テンプレートは使わない・F5-5）を `UIHostingController` で載せる。クリック計測・
/// 遷移は SDK が `headlineView` / `bodyView` / `callToActionView` / `iconView` に登録した
/// アセットビュー経由で行うため、`AdNativeCard` 側はタップ処理を持たない
/// （`AdNativeCard` のドキュメント参照）。
private struct NativeAdRepresentable: UIViewRepresentable {
    let adUnitID: String
    /// 要求はできたが配信されなかった（no-fill・ネットワーク失敗）場合に呼ぶ（F4-4 / F5-6）
    let onFailure: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> GADNativeAdView {
        let adView = GADNativeAdView()
        adView.setContentHuggingPriority(.defaultLow, for: .vertical)
        context.coordinator.attach(to: adView)
        context.coordinator.load(adUnitID: adUnitID)
        return adView
    }

    func updateUIView(_ uiView: GADNativeAdView, context: Context) {}

    /// `GADNativeAdLoaderDelegate` を受ける入れ物。SDK 型は本ファイル（`#if canImport`）の外に出さない。
    /// AdMob は本デリゲートをメインスレッドで呼ぶ（ドキュメント保証）ため `@MainActor` に固定し、
    /// `self` / `GADNativeAd`（非 Sendable）を境界越えで送信する必要が無いようにする
    /// （`MainActor.assumeIsolated` 越しの呼び出しは Swift 6 の region isolation で弾かれるため）。
    @MainActor
    final class Coordinator: NSObject, @preconcurrency GADNativeAdLoaderDelegate {
        private let onFailure: @MainActor () -> Void
        private var adLoader: GADAdLoader?
        private weak var adView: GADNativeAdView?
        private var hostingController: UIHostingController<AdNativeCard>?

        init(onFailure: @escaping @MainActor () -> Void) {
            self.onFailure = onFailure
        }

        func attach(to adView: GADNativeAdView) {
            self.adView = adView
        }

        func load(adUnitID: String) {
            guard let rootViewController = AdRequestFactory.currentRootViewController() else {
                onFailure()
                return
            }
            let loader = GADAdLoader(
                adUnitID: adUnitID,
                rootViewController: rootViewController,
                adTypes: [.native],
                options: nil
            )
            loader.delegate = self
            adLoader = loader
            loader.load(AdRequestFactory.makeRequest())
        }

        func adLoader(_ adLoader: GADAdLoader, didReceive nativeAd: GADNativeAd) {
            attach(nativeAd)
        }

        func adLoader(_ adLoader: GADAdLoader, didFailToReceiveAdWithError error: Error) {
            onFailure()
        }

        private func attach(_ nativeAd: GADNativeAd) {
            guard let adView else { return }

            // 画像取得失敗（`icon == nil`）時はテキストのみで描画する（F5-6 / plan.md E4）
            let content = AdNativeCardContent(
                headline: nativeAd.headline ?? "",
                body: nativeAd.body,
                callToAction: nativeAd.callToAction,
                icon: nativeAd.icon?.image.map { Image(uiImage: $0) }
            )

            let hosting = UIHostingController(rootView: AdNativeCard(content: content))
            hostingController = hosting
            hosting.view.backgroundColor = .clear
            hosting.view.translatesAutoresizingMaskIntoConstraints = false

            adView.subviews.forEach { $0.removeFromSuperview() }
            adView.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                hosting.view.topAnchor.constraint(equalTo: adView.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: adView.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: adView.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: adView.trailingAnchor),
            ])

            // クリック計測・遷移のためのアセットビュー登録。個別の UILabel / UIButton を持たないため
            // 同じホスティングビューを割り当てる（SDK は `nativeAd` セット後にタップ範囲を管理する）。
            adView.headlineView = hosting.view
            adView.bodyView = nativeAd.body != nil ? hosting.view : nil
            adView.iconView = nativeAd.icon != nil ? hosting.view : nil
            adView.callToActionView = nativeAd.callToAction != nil ? hosting.view : nil

            adView.nativeAd = nativeAd
        }
    }
}

/// バナー・ネイティブ共通のリクエスト生成・ルート VC 取得ヘルパー。
private enum AdRequestFactory {
    static func makeRequest() -> GADRequest {
        let request = GADRequest()
        let extras = GADExtras()
        // 非パーソナライズ広告固定（F1-4）。ATT / UMP は要求しない（docs/08 §2.8）。
        extras.additionalParameters = ["npa": "1"]
        request.register(extras)
        return request
    }

    @MainActor
    static func currentRootViewController() -> UIViewController? {
        // 既存パターン踏襲: `Packages/Network/Sources/Network/GoogleSignInService.swift` の
        // `WebAuthPresentationAnchorProvider.presentationAnchor(for:)`
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    }
}
#endif
