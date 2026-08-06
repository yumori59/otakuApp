import DesignSystem
import Domain

/// ログアウト / アカウント削除の共通後始末（`requirements.md` D4）。
///
/// `AuthStore.signOut()` / `AuthStore.deleteAccount(...)` は Keychain とセッション（access token・
/// `auth.signed_in_user`）だけを消す。**画面側の各ストアとテーマ設定はここで揃えてクリアする**
/// （旧 `AccountView` の logout 経路が `profile.clear()` しか呼んでいなかった取りこぼしの是正）。
///
/// `KeychainSharedBoardTokenStore`（他人から受け取った共有ボードのトークン）は**対象外**
/// （自アカウントと無関係な受信側の資産のため触らない）。
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
