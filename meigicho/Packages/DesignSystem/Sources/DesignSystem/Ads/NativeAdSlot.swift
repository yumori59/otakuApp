import SwiftUI

/// ネイティブ広告枠（F2-1 ホーム最下部 / F2-3 申込一覧インライン）。
///
/// バナー用の `AdSlot` と役割は同じだが、次の 2 点が違うので別型にしている:
/// - **幅の実測が要らない**: アダプティブバナーと違い、ネイティブは幅いっぱいに伸びるカード
///   （`AdNativeCard` = `AdCardChrome`）なので `GeometryReader` による幅計測が不要
/// - **高さがコンテンツ依存**: 見出し / 本文 / CTA の有無と行数で高さが変わる
///
/// レイアウト（AC-AD-34 / E18 / IOS-9）:
/// 広告カードは `UIViewRepresentable`（UIKit 側）で描かれるため、**SwiftUI はカードの
/// 実寸を自動では知らない**。`sizeThatFits` が最初に呼ばれるのはロード完了前（中身が空）で、
/// UIKit 側で中身が差し替わっても SwiftUI のレイアウトパスは走り直さない。
/// そのため `placeholderHeight` だけで包むと、実カード（見出し 2 行 + 本文 3 行 + CTA で
/// 180pt 前後）がはみ出して**後続コンテンツに重なる**（実測で確認済み）。
/// ここではレンダラから `onHeightChange` で実寸を受け取り、
/// `max(placeholderHeight, measuredHeight)` を**確定高**として与える。
/// ロード完了までは `placeholderHeight` を確保するのでリストは飛ばない（AC-AD-34）。
///
/// 次のいずれでも高さ 0 で何も描画しない（`AdSlot` と同じ）:
/// - `isVisible == false`（`AdGatekeeper.shouldShow` が false、または禁止面で構築自体をしない）
/// - `@Environment(\.adRenderer)` が `nil`（SDK 未注入・プレビュー・単体テスト）
/// - `adUnitID` が空（E1 / AC-AD-36）
/// - `AdRenderer.nativeAdView` が `nil` を返した / 配信されなかった（no-fill・ロード失敗。E3 / F4-4 / F5-6）
public struct NativeAdSlot: View {
    @Environment(\.adRenderer) private var adRenderer
    @State private var didFailToLoad = false
    @State private var measuredHeight: CGFloat = 0

    private let isVisible: Bool
    private let adUnitID: String

    /// ネイティブカード枠の最低高さ。ロード完了前後でリストが飛ばないよう事前に確保する
    /// （AC-AD-34）。実カードがこれより高い場合は `measuredHeight` で置き換わる。
    /// 内訳の目安: 「広告」ラベル 22 + spacing 8 + 見出し/本文 2 行 40 + padding 28。
    public static let placeholderHeight: CGFloat = 98

    public init(isVisible: Bool, adUnitID: String) {
        self.isVisible = isVisible
        self.adUnitID = adUnitID
    }

    public var body: some View {
        if isVisible, !didFailToLoad, adRenderer != nil, !adUnitID.isEmpty {
            content
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: max(Self.placeholderHeight, measuredHeight))
                .clipped()
        }
    }

    @ViewBuilder
    private var content: some View {
        // `nativeAdView` が返すのは `AdNativeCard`（= `AdCardChrome`）込みの完成ビュー。
        // ここで `AdCardChrome` を二重に被せない
        if let adRenderer,
           let native = adRenderer.nativeAdView(
               adUnitID: adUnitID,
               onFailure: { didFailToLoad = true },
               onHeightChange: { height in
                   guard height > 0, height != measuredHeight else { return }
                   measuredHeight = height
               }
           ) {
            native
        } else {
            Color.clear.onAppear { didFailToLoad = true }
        }
    }
}
