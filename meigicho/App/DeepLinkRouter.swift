import SwiftUI
import Features
import Domain
import Network

/// 共有リンクのディープリンク受け口（`plan.md` §7.7 Q16）。
///
/// **採用したエントリポイントは 2 経路だけ**:
/// 1. カスタムスキーム `meigicho://share/<token>`（このファイル）
/// 2. アプリ内の「共有リンクを開く」への URL 貼り付け（`Features/SharedBoard/OpenSharedBoardView`）
///
/// Universal Links（`https://…` のタップでアプリが開く）は `apple-app-site-association` の配置が
/// 必要で、`docs/09-roadmap.md` 1-7（Next.js 共有 Web）と同時の**別計画**。ここでは扱わない。
///
/// **この経路は Bearer 認証を使わない。** 資格情報は URL 中の token だけで、
/// 受け取った人は自分のアカウントでログインしていない前提（`contract-mapping.md` §5.1）。
/// そのため `SharedBoardStore` は `PublicApiClient` 実装の Repository だけを持ち、
/// `AuthStore` / `ApiClient` / `TokenStore` とは配線で結ばない。
struct SharedBoardDeepLink: ViewModifier {
    /// 共有ボード専用のストア。**アプリ本体のストア群とは独立**
    @State private var store: SharedBoardStore
    /// ディープリンクで開いている token（モーダル表示）
    @State private var presentedToken: String?

    init(environment: AppEnvironment) {
        _store = State(initialValue: SharedBoardStore(
            repository: environment.sharedBoardRepository,
            tokenStore: environment.sharedBoardTokenStore
        ))
    }

    func body(content: Content) -> some View {
        content
            // 画面内の「共有リンクを開く」からも同じストアを使う
            .environment(store)
            .onOpenURL { url in
                // token として読めない URL は無視する（Google の OAuth コールバックなど）
                guard let token = SharedBoardLink.token(from: url) else { return }
                presentedToken = token
            }
            .fullScreenCover(item: presentedTokenBinding) { presented in
                SharedBoardScreen(token: presented.token) {
                    presentedToken = nil
                    store.close()
                }
                .environment(store)
            }
    }

    private var presentedTokenBinding: Binding<PresentedShareToken?> {
        Binding(
            get: { presentedToken.map(PresentedShareToken.init(token:)) },
            set: { presentedToken = $0?.token }
        )
    }
}

/// `fullScreenCover(item:)` に渡すための薄いラッパー。
private struct PresentedShareToken: Identifiable, Hashable {
    let token: String
    var id: String { token }
}

extension View {
    /// `meigicho://share/<token>` を受けて共有ボードを開けるようにする。
    func sharedBoardDeepLink(environment: AppEnvironment) -> some View {
        modifier(SharedBoardDeepLink(environment: environment))
    }
}
