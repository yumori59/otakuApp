import SwiftUI

/// 広告枠。表示可否は `Domain.AdGatekeeper` / `AdsStore` が判定した結果を `isVisible` として
/// 呼び出し側（`Features`）から受け取るだけで、`DesignSystem` パッケージ自体は `Domain` に
/// 依存しない（`Package.swift` は `Core` のみに依存 / IOS-5）。
///
/// 次のいずれでも高さ 0 で何も描画しない:
/// - `isVisible == false`（`AdGatekeeper.shouldShow` が false、または禁止面で構築自体をしない）
/// - `@Environment(\.adRenderer)` が `nil`（SDK 未注入・プレビュー・単体テスト）
/// - `adUnitID` が空（E1 / AC-AD-36）
/// - `AdRenderer.bannerView` が `nil` を返した / 配信されなかった（no-fill・ロード失敗。E3 / F4-4）
///
/// レイアウト（AC-AD-34 / E18）: 高さは `placeholderHeight` を**下限**として確保し、
/// 実バナーがそれより高い場合は伸ばす。`GeometryReader` は幅の計測にだけ使い、
/// 高さの決定には使わない（`GeometryReader` は子をクリップしないため、
/// 固定高で包むと後続コンテンツに重なる）。
public struct AdSlot: View {
    @Environment(\.adRenderer) private var adRenderer
    @State private var didFailToLoad = false
    @State private var measuredWidth: CGFloat = 0

    private let isVisible: Bool
    private let adUnitID: String

    /// インライン・アダプティブバナー枠の最低高さ。ロード完了前後でリストが飛ばないよう
    /// 事前に確保する（AC-AD-34）。実バナーが高い場合はこの値を超えて伸びる。
    public static let placeholderHeight: CGFloat = 100

    public init(isVisible: Bool, adUnitID: String) {
        self.isVisible = isVisible
        self.adUnitID = adUnitID
    }

    public var body: some View {
        if isVisible, !didFailToLoad, adRenderer != nil, !adUnitID.isEmpty {
            content
                .frame(maxWidth: .infinity, minHeight: Self.placeholderHeight, alignment: .top)
                .background(widthReader)
        }
    }

    @ViewBuilder
    private var content: some View {
        // 幅が確定するまでは枠だけ確保しておく（バナーのアダプティブ幅は実測値が要る）
        if measuredWidth > 0, let adRenderer {
            if let banner = adRenderer.bannerView(
                adUnitID: adUnitID,
                width: measuredWidth,
                onFailure: { didFailToLoad = true }
            ) {
                AdCardChrome { banner }
            } else {
                Color.clear.onAppear { didFailToLoad = true }
            }
        } else {
            Color.clear
        }
    }

    /// 高さに影響しない幅の計測だけを行う（`background` なので親のサイズを変えない）。
    private var widthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { measuredWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, newWidth in measuredWidth = newWidth }
        }
    }
}
