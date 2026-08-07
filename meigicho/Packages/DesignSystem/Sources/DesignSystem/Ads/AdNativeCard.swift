import SwiftUI

/// ネイティブ広告 1 件分の表示データ（SDK 非依存）。
///
/// `App/Ads/GoogleMobileAdsRenderer.swift` が `GADNativeAd` のアセット（headline / body /
/// icon / callToAction）をこの型に変換してから `AdNativeCard` へ渡す。`DesignSystem` は
/// `GoogleMobileAds` を import しない（IOS-5 / `docs/plans/admob-integration/plan.md` §4 D4）。
public struct AdNativeCardContent: Sendable {
    public let headline: String
    public let body: String?
    public let callToAction: String?
    /// アイコン画像。取得失敗 / 未提供時は `nil`（F5-6 / plan.md E4 — テキストのみで描画する）
    public let icon: Image?

    public init(headline: String, body: String?, callToAction: String?, icon: Image?) {
        self.headline = headline
        self.body = body
        self.callToAction = callToAction
        self.icon = icon
    }
}

/// ネイティブ広告のカスタムレイアウト（F2-1 / F2-3, F5-5）。
///
/// - AdMob のネイティブテンプレート（`GADNativeAdView` 標準 XIB）は使わず、`AdCardChrome`
///   （`ticket-row` と同じ角丸 / 枠線 / 背景 / padding 14）でカスタム描画する
/// - 見出し 16px（`DSFont.bodyBold`）/ 本文 14px（`DSFont.caption`）。14px 未満は使わない（F5-5）
/// - CTA は `AdCTAButtonStyle`（枠線ボタン）で `btn-primary-block` と見分けがつく（F5-4）
/// - 推しカラーは適用しない。常にニュートラル（`AdCardChrome` と同じ方針、F5-3）
/// - 画像取得に失敗した場合（`content.icon == nil`）はアイコン領域ごと省き、
///   テキストのみで描画する。空枠・プレースホルダの隙間を残さない（F5-6 / plan.md E4）
///
/// タップ処理は持たない（純粋な表示のみ）。AdMob SDK 側が `GADNativeAdView` に登録した
/// アセットビュー経由でクリック計測・遷移を行うため、CTA ボタンはヒットテストを無効化して
/// SDK のジェスチャー認識に譲る（`GoogleMobileAdsRenderer` 側の配線を参照）。
public struct AdNativeCard: View {
    private let content: AdNativeCardContent

    public init(content: AdNativeCardContent) {
        self.content = content
    }

    public var body: some View {
        AdCardChrome {
            HStack(alignment: .top, spacing: 10) {
                if let icon = content.icon {
                    icon
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(content.headline)
                        .font(DSFont.bodyBold)
                        .foregroundStyle(DS.Gray.g900)
                        .lineLimit(2)

                    if let body = content.body, !body.isEmpty {
                        Text(body)
                            .font(DSFont.caption)
                            .foregroundStyle(DS.Gray.g600)
                            .lineLimit(3)
                    }
                }

                Spacer(minLength: 0)
            }

            if let callToAction = content.callToAction, !callToAction.isEmpty {
                // `AdCTAButtonStyle` と同じ見た目（枠線ボタン、F5-4）。ただし `Button` にはしない —
                // タップは SDK が `GADNativeAdView.callToActionView` に登録したアセットビューに
                // 譲るため、ここでは表示のみでヒットテストを持たない（二重のタップ経路を作らない）。
                Text(callToAction)
                    .font(DSFont.captionBold)
                    .foregroundStyle(DS.Gray.g600)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .stroke(DS.Gray.g400, lineWidth: 1)
                    )
                    .allowsHitTesting(false)
            }
        }
    }
}
