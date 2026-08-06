import SwiftUI
import DesignSystem
import Domain

#if canImport(UIKit)
import UIKit
#endif

/// 共有リンクをアプリで開くための入口（**URL 貼り付け経路**）。
///
/// エントリポイントは 2 経路（`plan.md` §7.7 Q16）:
/// 1. カスタムスキーム `meigicho://share/<token>`（`App/DeepLinkRouter.swift`）
/// 2. この画面に URL を貼り付ける
///
/// **Universal Links は本計画のスコープ外**（`apple-app-site-association` の配置が必要なため）。
struct OpenSharedBoardView: View {
    @Environment(SharedBoardStore.self) private var store
    @Environment(\.themeStore) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var path = NavigationPath()
    @State private var input = ""
    @State private var showsFormatError = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BigTitle("共有リンクを開く", subtitle: "受け取った共有リンクの URL を貼り付けてください")

                    FormCard {
                        TextField("https://… または meigicho://share/…", text: $input)
                            .font(DSFont.body)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(14)
                    }
                    FormHint(
                        showsFormatError
                            ? "共有リンクとして読み取れませんでした。URL をもう一度確認してください"
                            : "ログインしていなくても開けます。",
                        isError: showsFormatError
                    )

                    #if canImport(UIKit)
                    TourActionButton("クリップボードから貼り付け") {
                        input = UIPasteboard.general.string ?? input
                        showsFormatError = false
                    }
                    .padding(.top, 4)
                    #endif

                    PrimaryButton("開く") {
                        // token の中身は解釈しない。形式だけ見て取り出す
                        guard let token = SharedBoardLink.token(from: input) else {
                            showsFormatError = true
                            return
                        }
                        showsFormatError = false
                        path.append(AppRoute.sharedBoard(token: token))
                    }
                    .padding(.top, 16)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(theme.bgApp)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
            }
            .appNavigationDestinations(path: $path)
        }
    }
}

#Preview("共有リンクを開く") {
    OpenSharedBoardView()
        .environment(SharedBoardStore())
        .environment(IdentityStore())
        .environment(ApplicationStore())
        .environment(AppSettingsStore())
        .environment(AuthStore.preview(state: .signedOut))
        .environment(ProfileStore())
        .environment(ShareLinkStore())
        .environment(SheetPresenter())
        .environment(\.themeStore, ThemeStore())
}
