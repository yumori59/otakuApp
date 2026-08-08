import DesignSystem
import Domain

/// ログアウト / アカウント削除の共通後始末（`requirements.md` D4）。
///
/// `AuthStore.signOut()` / `AuthStore.deleteAccount(...)` は Keychain とセッション（access token・
/// `auth.signed_in_user`）だけを消す。**画面側の各ストアとテーマ設定はここで揃えてクリアする**
/// （旧 `AccountView` の logout 経路が `profile.clear()` しか呼んでいなかった取りこぼしの是正）。
///
/// 受信箱（`SharedInboxStore`）と共有ボード（`SharedBoardStore`）は**ここでは触らない**。
/// どちらもサーバーが正のメモリ上のデータで、`AuthState.signedOut` を受けた App 層の
/// `SharedBoardDeepLink`（`App/DeepLinkRouter.swift`）が一括で捨てる。
@MainActor
enum AccountLocalDataClearing {
    static func clearAll(
        profile: ProfileStore,
        identityStore: IdentityStore,
        applicationStore: ApplicationStore,
        shareLinkStore: ShareLinkStore,
        appSettings: AppSettingsStore,
        theme: ThemeStore
    ) {
        profile.clear()
        identityStore.clear()
        applicationStore.clear()
        shareLinkStore.clear()
        appSettings.appDisplayName = nil
        // アカウント由来の設定（背景カラー）を既定色に戻す（`docs/08` 「端末内データも破棄」）
        theme.apply(hex: "#0017C1")
    }
}
