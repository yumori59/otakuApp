import SwiftUI

/// 広告カードの共通クロム（`docs/07-monetization.md` §7.6 のデザイン規約）。
///
/// - 既存カード（`TicketRowView`）と同じ形状トークンを流用する: `DS.Radius.md` の角丸 /
///   `DS.Gray.g200` の 1px 枠 / `DS.surface` 背景 / `padding 14`
/// - 推しカラーテーマ（`ThemeStore.applyTheme()`）を適用しない。常にニュートラル（`DS.Gray.*`）
/// - 左上に「広告」ラベル（`AdLabel`、`.tag` と同じ 14px スタイル）を必ず表示する
public struct AdCardChrome<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdLabel()
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(DS.Gray.g200, lineWidth: 1)
        )
    }
}

/// カード左上に付く「広告」ラベル（`docs/07:443`）。
/// 「Sponsored」「PR」ではなく日本語の「広告」に統一し、`TagView` と同じニュートラル配色を使う。
public struct AdLabel: View {
    public init() {}

    public var body: some View {
        Text("広告")
            .font(DSFont.caption)
            .foregroundStyle(DS.Gray.g600)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(DS.Gray.g100)
            .clipShape(Capsule())
            .accessibilityLabel("広告")
    }
}

/// 広告 CTA 用のボタンスタイル。`docs/07:446`「CTAを主ボタンと同じ見た目にしない」に従い、
/// 塗りつぶし（`btn-primary-block` 相当）ではなく常に枠線ボタン・ニュートラル配色にする。
public struct AdCTAButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DSFont.captionBold)
            .foregroundStyle(DS.Gray.g600)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm)
                    .stroke(DS.Gray.g400, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == AdCTAButtonStyle {
    public static var adCTA: AdCTAButtonStyle { AdCTAButtonStyle() }
}
