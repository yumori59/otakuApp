import SwiftUI
import Domain

/// ゲスト（未ログイン）閲覧モードの判定と誘導文言（`questions-requirements.md` Q5）。
///
/// 起動時の全画面ログインゲートは廃止し、**未ログインでもタブ・画面には入れる**。
/// ただしサーバーに保存が無いので一覧は空になり、書き込み操作はログイン画面へ誘導する。
/// （`docs/08-compliance-risk.md:523` — サインインを必須にしない）
extension AuthStore {
    /// ゲスト（未ログイン）か。
    ///
    /// `.unknown` は起動直後の Keychain 復帰待ちで、`AuthGateView` がスプラッシュを出すため
    /// **タブには到達しない**。この状態をゲスト扱いしないことで、`#Preview` は従来どおり
    /// `SampleData` を描ける。
    var isGuest: Bool { state == .signedOut }
}

/// ログイン誘導の文言。散らばらないようここに集約する。
enum SignInPrompt {
    // 閲覧（案内）
    static let home = "ログインすると、名義・申込の状況がここに表示されます。"
    static let identities = "ログインすると、登録した名義がここに表示されます。"
    static let applications = "ログインすると、登録した申込がここに表示されます。"

    // 書き込み（ログインが必要）
    static let addIdentity = "名義を追加するにはログインが必要です。"
    static let addApplication = "申込を追加するにはログインが必要です。"
    static let editApplication = "申込を編集するにはログインが必要です。"
    static let editTour = "ツアーを編集するにはログインが必要です。"
    static let addAny = "名義や申込を登録するにはログインが必要です。"
    static let share = "ツアー表を共有するにはログインが必要です。"
}

extension SheetPresenter {
    /// 書き込み操作の入口。
    ///
    /// **未ログインならフォームを開かず、その場でログイン画面を出す**（Q5）。
    /// 入力させてから保存で失敗させると、入力内容が無駄になる。
    @MainActor
    func present(_ sheet: AppSheet, requiringSignIn auth: AuthStore, reason: String) {
        activeSheet = auth.isGuest ? .signIn(reason: reason) : sheet
    }

    /// 閲覧の案内カードなどからログイン画面を出す（理由の見出しは付けない）。
    @MainActor
    func presentSignIn(reason: String? = nil) {
        activeSheet = .signIn(reason: reason)
    }

    /// 名義追加。上限到達時はフォームを開かずペイウォールを出す（`docs/07` §6.2-A）。
    @MainActor
    func presentAddIdentity(
        auth: AuthStore,
        profile: ProfileStore,
        identityCount: Int
    ) {
        if auth.isGuest {
            activeSheet = .signIn(reason: SignInPrompt.addIdentity)
            return
        }
        let entitlement = profile.entitlement ?? Entitlement(plan: .free, identityLimit: 10, shareLimit: 1)
        if !entitlement.canAddIdentity(currentCount: identityCount) {
            activeSheet = .paywall(.identityLimit)
            return
        }
        activeSheet = .addIdentity
    }

    @MainActor
    func presentPaywall(_ trigger: PaywallTrigger) {
        activeSheet = .paywall(trigger)
    }
}
