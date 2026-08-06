import SwiftUI

/// 未ログイン（ゲスト）状態の案内カード（`questions-requirements.md` Q5）。
///
/// **これはエラーではなく案内**なので `ErrorBar` とは意図的に見た目を変える
/// （赤・警告アイコンを使わない）。「読み込みに失敗した」と誤解させないこと。
///
/// 未ログインでも画面には入れるが、表示できるデータがサーバーに無い状態で使う。
public struct SignInPromptCard: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    @Environment(\.themeStore) private var theme

    public init(
        title: String = "ログインするとご利用いただけます",
        message: String,
        actionTitle: String = "ログインする",
        action: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(theme.primary)
                .padding(.bottom, 2)
            Text(title)
                .font(DSFont.bodyBold)
                .foregroundStyle(DS.Gray.g900)
                .multilineTextAlignment(.center)
            Text(message)
                .font(DSFont.caption)
                .foregroundStyle(DS.Gray.g600)
                .multilineTextAlignment(.center)
            PrimaryButton(actionTitle, action: action)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    VStack(spacing: 16) {
        SignInPromptCard(message: "ログインすると、登録した名義がここに表示されます。") {}
        SignInPromptCard(
            title: "ログインが必要です",
            message: "名義を追加するにはログインが必要です。",
            actionTitle: "ログインへ進む"
        ) {}
    }
    .padding(16)
    .background(DS.Gray.g50)
}
