import SwiftUI

/// ネイティブ広告枠（F2-1 ホーム最下部 / F2-3 申込一覧インライン）。
///
/// バナー用の `AdSlot` と役割は同じだが、次の 2 点が違うので別型にしている:
/// - **幅の実測が要らない**: アダプティブバナーと違い、ネイティブは幅いっぱいに伸びるカード
///   （`AdNativeCard` = `AdCardChrome`）なので `GeometryReader` による幅計測が不要
/// - **高さがコンテンツ依存**: 見出し / 本文 / CTA の有無で高さが変わる。固定高で包まず、
///   `placeholderHeight` を**下限**としてだけ確保する（IOS-9 / AC-AD-34 / E18）
///
/// 次のいずれでも高さ 0 で何も描画しない（`AdSlot` と同じ）:
/// - `isVisible == false`（`AdGatekeeper.shouldShow` が false、または禁止面で構築自体をしない）
/// - `@Environment(\.adRenderer)` が `nil`（SDK 未注入・プレビュー・単体テスト）
/// - `adUnitID` が空（E1 / AC-AD-36）
/// - `AdRenderer.nativeAdView` が `nil` を返した / 配信されなかった（no-fill・ロード失敗。E3 / F4-4 / F5-6）
public struct NativeAdSlot: View {
    @Environment(\.adRenderer) private var adRenderer
    @State private var didFailToLoad = false

    private let isVisible: Bool
    private let adUnitID: String

    /// ネイティブカード枠の最低高さ。ロード完了前後でリストが飛ばないよう事前に確保する
    /// （AC-AD-34）。実カードがこれより高い場合はこの値を超えて伸びる。
    /// 内訳の目安: 「広告」ラベル 22 + spacing 8 + 見出し/本文 2 行 40 + padding 28。
    public static let placeholderHeight: CGFloat = 98

    public init(isVisible: Bool, adUnitID: String) {
        self.isVisible = isVisible
        self.adUnitID = adUnitID
    }

    public var body: some View {
        if isVisible, !didFailToLoad, adRenderer != nil, !adUnitID.isEmpty {
            content
                .frame(maxWidth: .infinity, minHeight: Self.placeholderHeight, alignment: .top)
        }
    }

    @ViewBuilder
    private var content: some View {
        // `nativeAdView` が返すのは `AdNativeCard`（= `AdCardChrome`）込みの完成ビュー。
        // ここで `AdCardChrome` を二重に被せない
        if let adRenderer,
           let native = adRenderer.nativeAdView(
               adUnitID: adUnitID,
               onFailure: { didFailToLoad = true }
           ) {
            native
        } else {
            Color.clear.onAppear { didFailToLoad = true }
        }
    }
}
