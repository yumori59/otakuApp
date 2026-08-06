import Foundation
import Core

/// `GET /v1/me` / `PATCH /v1/me` のストア（`contract-mapping.md` §4.2）。
///
/// - アカウント設定画面（`AccountView`）が唯一の利用者
/// - **`account_id` / `plan` は読み取り専用**。PATCH の経路を作らない（送ると 400 = C6 / AC-ME-03）
/// - 保存は「1 フィールドずつ PATCH」。BE は送られたキーのみ更新するので、
///   同時編集で他のフィールドを巻き戻さない
@MainActor
@Observable
public final class ProfileStore {
    public private(set) var profile: UserProfile?
    public private(set) var entitlement: Entitlement?
    public private(set) var state: LoadState = .idle
    public private(set) var isSaving = false
    /// 保存に失敗したときだけ入る。表示後は View 側で消してよい
    public var errorMessage: String?

    private let repository: (any ProfileRepository)?
    private let logger = AppLogger(category: "me")

    /// 引数を省略した形は **Preview 専用**（ネットワークに触らない）。
    public init(repository: (any ProfileRepository)? = nil) {
        self.repository = repository
    }

    // MARK: - 参照

    public var accountID: String? { profile?.accountID }
    public var email: String? { profile?.email }
    public var username: String? { profile?.username }
    public var appDisplayName: String? { profile?.appDisplayName }
    public var themeColor: String? { profile?.themeColor }

    /// `auth_providers`。**未知の値が増えてもクラッシュしない**（`[String]` のまま保持 — AC-ME-04）
    public var authProviders: [String] { profile?.authProviders ?? [] }

    /// 「パスワードを変更」を出してよいか。
    /// **`"email"` が含まれないのに `POST /v1/auth/password` を叩くと `FORBIDDEN` 403**（§4.2）。
    public var hasPasswordLogin: Bool { profile?.hasPasswordLogin ?? false }

    /// 表示用のラベル。**既知 3 値だけをラベル化し、未知値は無視してログに残す**（AC-ME-04）。
    public var authProviderLabels: [String] {
        authProviders.compactMap { raw in
            guard let label = Self.providerLabel(raw) else {
                logger.unknownValue(field: "auth_providers", rawValue: raw)
                return nil
            }
            return label
        }
    }

    static func providerLabel(_ raw: String) -> String? {
        switch raw {
        case "apple": "Apple"
        case "google": "Google"
        case "email": "メールアドレス"
        default: nil
        }
    }

    // MARK: - 読み込み

    /// ログイン直後・アカウント画面表示時に呼ぶ。
    /// 失敗しても既読データは消さない（E-1）。
    public func load() async {
        guard let repository else { return }
        state = .loading
        do {
            apply(try await repository.fetchMe())
            state = .loaded
        } catch {
            state = .failed(Self.appError(from: error))
        }
    }

    /// ログアウト時に呼ぶ（別アカウントのプロフィールを残さない）。
    public func clear() {
        profile = nil
        entitlement = nil
        state = .idle
        errorMessage = nil
    }

    /// 購入直後の楽観的更新（Webhook 到着前。以降の `load()` は期限の長い方を残す）。
    public func applyEntitlement(_ entitlement: Entitlement) {
        self.entitlement = entitlement
    }

    // MARK: - 保存

    /// ユーザーネーム。空文字は `null`（クリア）として送る。
    /// BE は `username` を 1〜30 文字で検証するため、空文字をそのまま送ると 400 になる。
    @discardableResult
    public func saveUsername(_ value: String) async -> Bool {
        var patch = ProfilePatch()
        patch.username = .set(Self.trimmedOrNil(value))
        return await save(patch)
    }

    /// アプリ表示名。空文字は `null`（クリア）。
    @discardableResult
    public func saveAppDisplayName(_ value: String) async -> Bool {
        var patch = ProfilePatch()
        patch.appDisplayName = .set(Self.trimmedOrNil(value))
        return await save(patch)
    }

    /// 背景カラー。**`^#[0-9A-Fa-f]{6}$` に合わない値は送らない**（400 を往復させない）。
    @discardableResult
    public func saveThemeColor(_ hex: String) async -> Bool {
        guard Self.isValidThemeColor(hex) else {
            logger.unknownValue(field: "theme_color", rawValue: hex)
            return false
        }
        guard profile?.themeColor != hex else { return true }
        var patch = ProfilePatch()
        patch.themeColor = .set(hex)
        return await save(patch)
    }

    /// 1 フィールド分の PATCH。**成功したらサーバーの応答で丸ごと差し替える**（サーバーが正）。
    @discardableResult
    public func save(_ patch: ProfilePatch) async -> Bool {
        guard let repository else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            apply(try await repository.updateMe(patch))
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.appError(from: error).userMessage
            return false
        }
    }

    // MARK: - 内部

    private func apply(_ snapshot: MeSnapshot) {
        profile = snapshot.profile
        entitlement = Entitlement.mergingPreferringLongerAccess(
            local: entitlement,
            remote: snapshot.entitlement
        )
    }

    static func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isValidThemeColor(_ hex: String) -> Bool {
        guard hex.count == 7, hex.hasPrefix("#") else { return false }
        return hex.dropFirst().allSatisfy(\.isHexDigit)
    }

    static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "UNEXPECTED", message: nil)
    }
}
