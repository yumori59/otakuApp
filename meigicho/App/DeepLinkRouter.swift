import SwiftUI
import Features
import Domain
import Network

/// 共有リンクのディープリンク受け口（`api-contract-delta.md` §4.4 / FR-4）。
///
/// **採用したエントリポイントは 1 経路だけ**: カスタムスキーム `meigicho://share/<token>`。
/// アプリ内の URL 貼り付け画面（旧 `OpenSharedBoardView`）は「未ログインで開ける入口を残さない」ため削除済み（FR-4-1 / Q11）。
/// Universal Links（`https://…` のタップ）は `apple-app-site-association` の配置が必要で、
/// `docs/09-roadmap.md` 1-7（Next.js 共有 Web）と同時の**別計画**。ここでは扱わない。
///
/// **この経路は Bearer 認証を使う。** 共有は招待されたアカウントだけが開けるようになったので
/// （Q1=A で `/public/*` は廃止）、受け取り側も必ず自分のアカウントでログイン済みである必要がある:
///
/// 1. token を受け取る → **未ログインならサインインを促し、token を保留**（FR-4-3 / AC-SI-73-M）
/// 2. `POST /v1/shares/received/redeem` で `share_id` に交換（`SharedInboxStore.redeem`）
/// 3. `share_id` でボードをモーダル表示（`SharedBoardScreen`）
/// 4. 交換に失敗したらアラート 1 行だけ出す。403 は「あなたに共有されていません」、
///    404 は未知 / 失効 / 期限切れを区別しない（FR-4-4 / NFR-1）
///
/// 受信箱（`SharedInboxStore`）と共有ボード（`SharedBoardStore`）の **Environment 注入もここが単独所有する**
/// （`HomeView` のバッジ・`SharedInboxView` / `SharedBoardView` が `@Environment` で受け取る — IOS-5）。
struct SharedBoardDeepLink: ViewModifier {
    /// 受信箱。一覧・未読バッジ・`redeem` を担う。**サーバーが正でローカル永続化しない**
    @State private var inboxStore: SharedInboxStore
    /// 共有ボード（受け取り側）。`share_id` で開く
    @State private var boardStore: SharedBoardStore
    /// ディープリンクで開いている共有（モーダル表示）
    @State private var presentedShareID: UUID?
    /// 未ログイン中に受け取った token。**サインイン後に再試行する**（FR-4-3）
    @State private var pendingToken: String?
    /// `redeem` 失敗の 1 行メッセージ
    @State private var redeemError: AppError?

    /// サインイン完了を待つために親から渡される（この修飾子は `.environment(authStore)` の**外側**にいるので
    /// `@Environment(AuthStore.self)` では受け取れない）
    private let authState: AuthState
    /// 未ログイン時のサインイン導線（`GuestGate` と同じ仕組み）
    private let sheetPresenter: SheetPresenter

    init(environment: AppEnvironment, authState: AuthState, sheetPresenter: SheetPresenter) {
        _inboxStore = State(initialValue: SharedInboxStore(repository: environment.sharedInboxRepository))
        _boardStore = State(initialValue: SharedBoardStore(
            repository: environment.sharedBoardRepository,
            inboxRepository: environment.sharedInboxRepository
        ))
        self.authState = authState
        self.sheetPresenter = sheetPresenter
    }

    func body(content: Content) -> some View {
        content
            .environment(inboxStore)
            .environment(boardStore)
            .onOpenURL { url in
                // token として読めない URL は**何もせず無視する**（Google Sign-In の OAuth コールバックなど。
                // ここで握りつぶすと `MeigichoApp` 側の `onOpenURL` にも届かなくなるわけではない — 併走する）
                guard let token = SharedBoardLink.token(from: url) else { return }
                receive(token: token)
            }
            .task(id: authState) {
                await handleAuthStateChange()
            }
            .fullScreenCover(item: presentedShareIDBinding) { presented in
                SharedBoardScreen(shareID: presented.id) {
                    presentedShareID = nil
                    boardStore.close()
                }
                .environment(boardStore)
            }
            .alert(
                "共有を開けませんでした",
                isPresented: redeemErrorBinding,
                presenting: redeemError
            ) { _ in
                Button("OK") { redeemError = nil }
            } message: { error in
                Text(error.userMessage)
            }
    }

    // MARK: - token の受け取り

    /// ログイン済みならすぐ交換、未ログインなら保留してサインインを促す（FR-4-3）。
    private func receive(token: String) {
        guard authState == .signedIn else {
            pendingToken = token
            sheetPresenter.activeSheet = .signIn(reason: "共有された表を開くにはログインが必要です。")
            return
        }
        pendingToken = nil
        Task { await redeemAndPresent(token: token) }
    }

    /// `AuthState` の遷移に対する反応。
    ///
    /// - `.signedIn` — 保留していた token を**一度だけ**再試行する（保留を先に落として二重実行を防ぐ）
    /// - `.signedOut` — 前のユーザーの受信箱とボードをメモリから捨てる。
    ///   **どちらもサーバーが正でローカル永続化していない**ので、オフライン復帰失敗の `.signedOut`
    ///   （IOS-6）で消しても失われる未送信データは無い。**保留 token は消さない**（サインインの続きで使う）
    private func handleAuthStateChange() async {
        switch authState {
        case .signedIn:
            guard let token = pendingToken else { return }
            pendingToken = nil
            await redeemAndPresent(token: token)
        case .signedOut:
            presentedShareID = nil
            boardStore.close()
            inboxStore.clear()
        case .unknown:
            break
        }
    }

    /// token → `share_id` → ボード表示。
    private func redeemAndPresent(token: String) async {
        guard let shareID = await inboxStore.redeem(token: token) else {
            // `.shareNotInvited`（403・招待されていない）/ `.shareInvalid`（404・未知 / 失効 / 期限切れ）。
            // **理由を推測して説明しない**（NFR-1）
            redeemError = inboxStore.actionError
            inboxStore.clearActionError()
            return
        }
        // 受信箱を開いていた場合の未読も落とす（正はサーバー。次の `load()` で上書きされる）
        inboxStore.markRead(shareID: shareID)
        presentedShareID = shareID
    }

    // MARK: - Binding

    private var presentedShareIDBinding: Binding<PresentedShare?> {
        Binding(
            get: { presentedShareID.map(PresentedShare.init(id:)) },
            set: { presentedShareID = $0?.id }
        )
    }

    private var redeemErrorBinding: Binding<Bool> {
        Binding(
            get: { redeemError != nil },
            set: { if !$0 { redeemError = nil } }
        )
    }
}

/// `fullScreenCover(item:)` に渡すための薄いラッパー。
private struct PresentedShare: Identifiable, Hashable {
    let id: UUID
}

extension View {
    /// `meigicho://share/<token>` を受けて共有ボードを開けるようにし、
    /// 受信箱 / 共有ボードのストアを Environment に注入する。
    func sharedBoardDeepLink(
        environment: AppEnvironment,
        authState: AuthState,
        sheetPresenter: SheetPresenter
    ) -> some View {
        modifier(SharedBoardDeepLink(
            environment: environment,
            authState: authState,
            sheetPresenter: sheetPresenter
        ))
    }
}
