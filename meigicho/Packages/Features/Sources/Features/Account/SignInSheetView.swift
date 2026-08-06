import SwiftUI
import DesignSystem
import Domain

/// シートで出すログイン画面（`questions-requirements.md` Q5）。
///
/// 未ログインのまま書き込み操作を押したときの誘導先。**ログインに成功したら自動で閉じる**ので、
/// ユーザーは元の画面に戻ってそのまま操作をやり直せる。
struct SignInSheetView: View {
    /// 「なぜログインが必要か」。閲覧の案内カードから開いたときは nil
    let reason: String?

    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SignInView(reason: reason)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onChange(of: auth.state) { _, state in
                // ログインできたら閉じる（誘導元の画面に戻す）
                if state == .signedIn { dismiss() }
            }
    }
}

#Preview {
    NavigationStack {
        SignInSheetView(reason: "名義を追加するにはログインが必要です。")
    }
    .environment(AuthStore.preview(state: .signedOut))
    .environment(\.themeStore, ThemeStore())
}
