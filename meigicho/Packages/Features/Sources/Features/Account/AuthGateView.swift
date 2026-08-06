import SwiftUI
import DesignSystem
import Domain

/// 起動時の**ソフト**ゲート（`questions-requirements.md` Q5）。
///
/// - `.unknown`: Keychain からの復帰待ち。ここだけスプラッシュで待つ
/// - `.signedOut`: **本体（`MainTabView`）を描く**。ゲスト（未ログイン）閲覧モード。
///   各画面が `AuthStore.isGuest` を見て、案内カードとログイン誘導を出す
/// - `.signedIn`: 本体（従来どおり）
///
/// 全画面ログインゲート（旧実装）は廃止した。`docs/08-compliance-risk.md:523`
/// 「サインインを必須にしない（Guideline 5.1.1(v)）」に合わせるため。
public struct AuthGateView<Content: View>: View {
    @Environment(AuthStore.self) private var auth
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        switch auth.state {
        case .unknown:
            AuthGateSplashView()
        case .signedOut, .signedIn:
            content()
        }
    }
}

struct AuthGateSplashView: View {
    @Environment(\.themeStore) private var theme

    var body: some View {
        VStack(spacing: 16) {
            Text("参戦名義帳")
                .font(DSFont.bigTitle)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bgApp)
    }
}

#Preview("復帰待ち（.unknown）") {
    AuthGateView {
        Text("本体")
    }
    .environment(AuthStore.preview(state: .unknown))
    .environment(\.themeStore, ThemeStore())
}

#Preview("ゲスト（.signedOut）") {
    // 未ログインでも本体を描く（Q5）
    AuthGateView {
        Text("本体")
    }
    .environment(AuthStore.preview(state: .signedOut))
    .environment(\.themeStore, ThemeStore())
}
