import SwiftUI

/// 広告枠。表示可否は `Domain.AdGatekeeper` / `AdsStore` が判定した結果を `isVisible` として
/// 呼び出し側（`Features`）から受け取るだけで、`DesignSystem` パッケージ自体は `Domain` に
/// 依存しない（`Package.swift` は `Core` のみに依存 / IOS-5）。
///
/// 次のいずれでも高さ 0 で何も描画しない:
/// - `isVisible == false`（`AdGatekeeper.shouldShow` が false、または禁止面で構築自体をしない）
/// - `@Environment(\.adRenderer)` が `nil`（SDK 未注入・プレビュー・単体テスト）
/// - `adUnitID` が空（E1 / AC-AD-36）
/// - `AdRenderer.bannerView` が `nil` を返した（ロード失敗。E3）
///
/// プレースホルダの高さは事前に固定し、ロード完了前後で変化させない
/// （`docs/07:448`「レイアウトを崩さない」/ AC-AD-34）。
public struct AdSlot: View {
    @Environment(\.adRenderer) private var adRenderer
    @State private var didFailToLoad = false

    private let isVisible: Bool
    private let adUnitID: String

    /// インライン・アダプティブバナーのプレースホルダ高さ。
    /// `GADCurrentOrientationInlineAdaptiveBannerAdSizeWithWidth` は端末幅で変動するが、
    /// 縦画面の一般的なバナー高さ（~50〜100pt）を上回らないため、この固定値で
    /// リストジャンプを防ぐ（AC-AD-34）。
    public static let placeholderHeight: CGFloat = 100

    public init(isVisible: Bool, adUnitID: String) {
        self.isVisible = isVisible
        self.adUnitID = adUnitID
    }

    public var body: some View {
        if isVisible, !didFailToLoad, let adRenderer, !adUnitID.isEmpty {
            GeometryReader { proxy in
                if let banner = adRenderer.bannerView(adUnitID: adUnitID, width: proxy.size.width) {
                    AdCardChrome { banner }
                } else {
                    Color.clear
                        .onAppear { didFailToLoad = true }
                }
            }
            .frame(height: Self.placeholderHeight)
        }
    }
}
