import Foundation
import Core

/// ログインゲートの状態（`questions-requirements.md` Q5）。
/// `.unknown` の間はタブもログイン画面も出さない（Keychain の復帰待ち）。
public enum AuthState: Equatable, Hashable, Sendable {
    case unknown
    case signedOut
    case signedIn
}

/// 起動時の復帰結果。
public enum SessionRestoreResult: Equatable, Sendable {
    case restored
    /// token が無い / 失効した。**Keychain はクリア済み**
    case signedOut
    /// 通信できないだけ（オフライン等）。**token は消していない**ので、再試行で復帰しうる
    case unavailable(AppError)
}

/// トークンの保持・回転・破棄を担う実体（実装は `Network.ApiClient`）。
/// **Domain は `Network` を知らない**ので protocol 越しに注入する（IOS-5）。
public protocol AuthSessionController: Sendable {
    /// ログイン成功時のトークンを採用する（access はメモリ / refresh は Keychain）。
    func adoptSession(_ tokens: TokenPair) async
    func clearSession() async
    func restoreSession() async -> SessionRestoreResult
    func currentRefreshToken() async -> String?
    /// refresh が復帰不能になったときに呼ばれる（サイレントログアウト）。
    func setSessionEndedHandler(_ handler: @escaping @Sendable () async -> Void) async
}

/// Google サインインで得る値。**BE に渡すのはこの 2 つだけ**（`contract-mapping.md` §4.1.1）。
public struct GoogleIdentity: Equatable, Sendable {
    /// Google が返した JWT。**加工しない**
    public let idToken: String
    /// 認可リクエストに載せたのと同じ文字列（sha256 しない）
    public let nonce: String

    public init(idToken: String, nonce: String) {
        self.idToken = idToken
        self.nonce = nonce
    }
}

/// Google サインインの実行（実装は `Network.GoogleSignInService`）。
public protocol GoogleSignInProviding: Sendable {
    /// **ユーザーキャンセルは `nil`**。エラーとして扱わない（E-14）
    func signIn() async throws -> GoogleIdentity?
}

/// 認証状態のストア。ログインゲート（`AuthGateView`）が参照する。
///
/// - Apple / Google / メール+パスワードの 3 方式
/// - access token は `AuthSessionController`（= `ApiClient`）がメモリに、refresh token は Keychain に持つ。
///   **このクラスはトークンを保持しない**
@MainActor
@Observable
public final class AuthStore {
    public private(set) var state: AuthState = .unknown
    public private(set) var user: SignedInUser?
    public private(set) var isBusy = false
    /// ログイン画面に出すエラー。**サイレントログアウト時は nil のまま**（AC-AUTH-09-M）
    public var errorMessage: String?

    public var accountIDCopied = false
    public var shareLinkCopied = false

    private let repository: any AuthRepository
    private let session: any AuthSessionController
    private let googleSignIn: (any GoogleSignInProviding)?
    private let userCache: SignedInUserCache
    /// 1 回のログイン試行ごとに作り、レスポンス受領で破棄する（Q4）
    private var pendingAppleNonce: String?

    public var loggedIn: Bool { state == .signedIn }
    public var accountID: String? { user?.accountID }
    /// Google の OAuth クライアント ID が設定されているか（未設定でもボタンは出し、押されたら理由を出す）
    public var isGoogleAvailable: Bool { googleSignIn != nil }

    /// 引数を省略した形は **Preview 専用**（ネットワークに触らない）。
    public init(
        repository: any AuthRepository = InMemoryAuthRepository(),
        session: any AuthSessionController = NoopAuthSessionController(),
        googleSignIn: (any GoogleSignInProviding)? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.session = session
        self.googleSignIn = googleSignIn
        self.userCache = SignedInUserCache(defaults: userDefaults)
    }

    // MARK: - 起動

    /// Keychain の refresh token でセッションを復帰する。
    public func bootstrap() async {
        await session.setSessionEndedHandler { [weak self] in
            await self?.handleSessionEnded()
        }
        await restore()
    }

    /// オフラインで復帰できなかったときの再試行（ログイン画面のボタン）。
    public func retryRestore() async {
        state = .unknown
        await restore()
    }

    private func restore() async {
        switch await session.restoreSession() {
        case .restored:
            user = userCache.load()
            state = .signedIn
            errorMessage = nil
        case .signedOut:
            // サイレントログアウト。アラートを出さない（ログイン画面に戻ることで伝わる）
            userCache.clear()
            user = nil
            state = .signedOut
        case .unavailable(let error):
            // token は消さない。通信が戻れば復帰できる
            user = nil
            state = .signedOut
            errorMessage = error.userMessage
        }
    }

    // MARK: - Sign in with Apple

    /// `ASAuthorizationAppleIDRequest.nonce` に設定する値を作って返す。
    /// **BE には同じ文字列をそのまま送る**（sha256 しない — Q4 / A2）。
    public func beginAppleSignIn() -> String {
        let nonce = Nonce.generate()
        pendingAppleNonce = nonce
        errorMessage = nil
        return nonce
    }

    public func completeAppleSignIn(identityToken: String) async {
        let nonce = pendingAppleNonce
        pendingAppleNonce = nil
        await performSignIn {
            try await self.repository.signInWithApple(identityToken: identityToken, nonce: nonce)
        }
    }

    /// 認可自体が失敗したとき（**キャンセルは呼ばない**）。
    public func failAppleSignIn() {
        pendingAppleNonce = nil
        isBusy = false
        errorMessage = AppError.appleSignInFailed.userMessage
    }

    // MARK: - Google

    public func signInWithGoogle() async {
        errorMessage = nil
        guard let googleSignIn else {
            // `GOOGLE_IOS_CLIENT_ID` が未設定。原因を推測させない文言にする
            errorMessage = "Google ログインは現在利用できません（アプリの設定が未完了です）"
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            guard let identity = try await googleSignIn.signIn() else {
                // ユーザーキャンセル。エラー表示しない（AC-GG-04-M）
                return
            }
            let authSession = try await repository.signInWithGoogle(
                idToken: identity.idToken,
                nonce: identity.nonce
            )
            await adopt(authSession)
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.googleSignInFailed.userMessage
        }
    }

    // MARK: - メール + パスワード

    // 5 経路とも **エラーは throw して呼び出し側（View）が文脈に応じた文言を出す**。
    // `AUTH_CREDENTIALS_INVALID` はログイン時と パスワード変更時で意味が違うため、
    // ここで `errorMessage` に丸めない（`contract-mapping.md` §2.3）。

    /// `POST /v1/auth/register`。成功すると**そのままログイン状態になる**。
    public func registerWithEmail(email: String, password: String) async throws {
        let address = EmailCredentialRule.normalizedEmail(email)
        try EmailCredentialRule.validateEmail(address)
        try EmailCredentialRule.validateNewPassword(password)
        try await performEmailSignIn {
            try await self.repository.register(email: address, password: password)
        }
    }

    /// `POST /v1/auth/login`。
    /// **パスワードの下限を掛けない** — 旧ポリシーのアカウントを 401 と区別できてしまうため（A7 / BE の `LoginDto` と同じ判断）。
    public func signInWithEmail(email: String, password: String) async throws {
        let address = EmailCredentialRule.normalizedEmail(email)
        try EmailCredentialRule.validateEmail(address)
        guard !password.isEmpty else { throw EmailCredentialError.passwordEmpty }
        try await performEmailSignIn {
            try await self.repository.login(email: address, password: password)
        }
    }

    /// `POST /v1/auth/password`（**Bearer 必須**）。
    ///
    /// 成功時、サーバーはその user の refresh token を**全件失効**させ新しいペアを返す。
    /// **返ってきたペアで Keychain を必ず上書きする**（捨てると自分自身が次の refresh でログアウトする — A5 / R9）。
    /// `auth_providers` に `"email"` が無いアカウントで叩くと `FORBIDDEN` 403 になるので、
    /// 呼び出し側は `UserProfile.hasPasswordLogin` が true のときだけ導線を出す。
    public func changePassword(current: String, new: String) async throws {
        try EmailCredentialRule.validateNewPassword(new)
        guard current != new else { throw EmailCredentialError.newPasswordSameAsCurrent }
        guard !isBusy else { throw EmailCredentialError.busy }
        isBusy = true
        defer { isBusy = false }

        let tokens = try await repository.changePassword(current: current, new: new)
        await session.adoptSession(tokens)
    }

    /// `POST /v1/auth/password/reset-request`。**202 / ボディ無し**。
    /// 登録の有無に関わらず同じ応答なので、**成功しても「送信しました」と断定しない**（A4）。
    /// 429（`.rateLimited`）でも**自動リトライしない**（A11）。
    public func requestPasswordReset(email: String) async throws {
        let address = EmailCredentialRule.normalizedEmail(email)
        try EmailCredentialRule.validateEmail(address)
        guard !isBusy else { throw EmailCredentialError.busy }
        isBusy = true
        defer { isBusy = false }

        try await repository.requestPasswordReset(email: address)
    }

    /// `POST /v1/auth/password/reset`。成功すると**そのままログイン状態になる**（A6）。
    public func resetPassword(email: String, code: String, newPassword: String) async throws {
        let address = EmailCredentialRule.normalizedEmail(email)
        try EmailCredentialRule.validateEmail(address)
        try EmailCredentialRule.validateResetCode(code)
        try EmailCredentialRule.validateNewPassword(newPassword)
        try await performEmailSignIn {
            try await self.repository.resetPassword(email: address, code: code, newPassword: newPassword)
        }
    }

    // MARK: - ログアウト

    public func signOut() async {
        isBusy = true
        defer { isBusy = false }

        if let refreshToken = await session.currentRefreshToken() {
            // サーバー側の失効に失敗しても、端末からは必ず消す
            try? await repository.logout(refreshToken: refreshToken)
        }
        await clearLocalSession()
    }

    // MARK: - アカウント削除

    /// `DELETE /v1/me`。成功したら `signOut()` と同じ後始末を行うが、
    /// **`POST /v1/auth/logout` は呼ばない**（refresh 行はサーバー側で削除済み）。
    /// 失敗時は状態を変えずに throw する。
    /// **`.notFound` を受けた場合も成功と同じ後始末を行ってから throw する**
    /// （既に削除済みとみなし、呼び出し側は文言だけ出し分ける — `api-contract-delta.md` §3.3）。
    public func deleteAccount(password: String?, appleAuthorizationCode: String?) async throws {
        // 二重送信の保険（`performEmailSignIn` と同じ扱い）。UI の `.disabled` だけに頼らない
        guard !isBusy else { throw EmailCredentialError.busy }
        isBusy = true
        defer { isBusy = false }

        do {
            try await repository.deleteAccount(password: password, appleAuthorizationCode: appleAuthorizationCode)
            await clearLocalSession()
        } catch AppError.notFound {
            await clearLocalSession()
            throw AppError.notFound
        }
    }

    // MARK: - 内部

    /// `signOut()` / `deleteAccount(...)` 共通の後始末。**`POST /v1/auth/logout` は呼ばない**。
    private func clearLocalSession() async {
        await session.clearSession()
        userCache.clear()
        user = nil
        errorMessage = nil
        state = .signedOut
    }

    /// メール系のサインイン。`performSignIn` と違い**エラーを throw する**（文言は呼び出し側が決める）。
    private func performEmailSignIn(_ operation: @escaping () async throws -> AuthSession) async throws {
        guard !isBusy else { throw EmailCredentialError.busy }
        isBusy = true
        defer { isBusy = false }
        await adopt(try await operation())
    }

    private func performSignIn(_ operation: @escaping () async throws -> AuthSession) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            await adopt(try await operation())
        } catch let error as AppError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = AppError.unknown(code: "SIGN_IN", message: nil).userMessage
        }
    }

    /// **トークンを採用し終えてから** `signedIn` にする（先に画面を切り替えると
    /// 直後の `/v1/*` 呼び出しが Bearer 無しで飛ぶ）。
    private func adopt(_ authSession: AuthSession) async {
        await session.adoptSession(authSession.tokens)
        user = authSession.user
        userCache.save(authSession.user)
        errorMessage = nil
        state = .signedIn
    }

    private func handleSessionEnded() {
        userCache.clear()
        user = nil
        pendingAppleNonce = nil
        state = .signedOut
    }
}

// MARK: - Preview 用

extension AuthStore {
    /// **Preview 専用**。ネットワークに触らず、指定した状態のストアを作る。
    ///
    /// `state` は `private(set)` なので同一ファイル内でしか作れない。
    /// 実行時経路（`MeigichoApp`）からは使わない。
    @MainActor
    public static func preview(state: AuthState, user: SignedInUser? = nil) -> AuthStore {
        let store = AuthStore()
        store.state = state
        store.user = user
        return store
    }
}

// MARK: - メール + パスワードの入力規則

/// クライアント側の入力チェック（`contract-mapping.md` A8〜A10）。
///
/// **サーバーと同じ制約だけを持つ。大文字必須などの独自ルールを足さない**（IOS-4 / AC-EM-03）。
/// 最終的な判断はサーバーにあり、ここは往復を減らすための事前チェックにすぎない。
public enum EmailCredentialRule {
    /// `password` は **8〜128 文字・文字種要件なし**（A9）
    public static let passwordMinLength = 8
    public static let passwordMaxLength = 128
    /// `email` は 255 文字以下（A10）
    public static let emailMaxLength = 255
    /// リセットコードは **8 桁の数字**（`^\d{8}$` — A8）
    public static let resetCodeLength = 8

    /// **trim だけする。小文字化（正規化）はサーバーの担当**（A10）。
    public static func normalizedEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 形式の最終判断はサーバー（`@IsEmail()`）。ここは明らかな誤入力だけ弾く。
    public static func isValidEmail(_ raw: String) -> Bool {
        let value = normalizedEmail(raw)
        guard value.count <= emailMaxLength else { return false }
        guard !value.contains(" ") else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return false }
        return !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    /// **長さだけ**を見る（AC-EM-03）。
    public static func isValidPassword(_ raw: String) -> Bool {
        (passwordMinLength...passwordMaxLength).contains(raw.count)
    }

    /// `^\d{8}$`（AC-EM-04）。全角数字は通さない。
    public static func isValidResetCode(_ raw: String) -> Bool {
        raw.count == resetCodeLength && raw.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func validateEmail(_ raw: String) throws {
        guard isValidEmail(raw) else { throw EmailCredentialError.emailInvalid }
    }

    static func validateNewPassword(_ raw: String) throws {
        guard isValidPassword(raw) else { throw EmailCredentialError.passwordLength }
    }

    static func validateResetCode(_ raw: String) throws {
        guard isValidResetCode(raw) else { throw EmailCredentialError.resetCodeFormat }
    }
}

/// 送信前に弾いた入力エラー。**サーバーの `AppError` とは別系統**（通信していないため）。
public enum EmailCredentialError: Error, Equatable, Sendable {
    case emailInvalid
    case passwordEmpty
    case passwordLength
    case resetCodeFormat
    case newPasswordSameAsCurrent
    /// 別の認証操作が進行中（二重送信の保険。**自動リトライはしない**）
    case busy

    public var userMessage: String {
        switch self {
        case .emailInvalid:
            "メールアドレスの形式を確認してください"
        case .passwordEmpty:
            "パスワードを入力してください"
        case .passwordLength:
            "パスワードは \(EmailCredentialRule.passwordMinLength)〜\(EmailCredentialRule.passwordMaxLength) 文字で入力してください"
        case .resetCodeFormat:
            "確認コードは \(EmailCredentialRule.resetCodeLength) 桁の数字です"
        case .newPasswordSameAsCurrent:
            "新しいパスワードは現在のパスワードと違うものにしてください"
        case .busy:
            "処理中です。しばらくお待ちください"
        }
    }
}

/// 表示用のユーザー情報キャッシュ。**トークンは入れない**（Keychain の担当）。
///
/// 再起動直後は `POST /v1/auth/refresh` しか叩かないため `user` がサーバーから返らない。
/// アカウント ID の表示が空になるのを防ぐためだけに持つ。
/// NOTE(T1b): `GET /v1/me` に接続したら、そちらの値で上書きするのが正。
struct SignedInUserCache {
    private let defaults: UserDefaults
    private let key = "auth.signed_in_user"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private struct Payload: Codable {
        let id: UUID
        let accountID: String?
        let displayName: String?
        let plan: String
    }

    func load() -> SignedInUser? {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return SignedInUser(
            id: payload.id,
            accountID: payload.accountID,
            displayName: payload.displayName,
            plan: Plan(rawValue: payload.plan) ?? .free,
            isNew: false
        )
    }

    func save(_ user: SignedInUser) {
        let payload = Payload(
            id: user.id,
            accountID: user.accountID,
            displayName: user.displayName,
            plan: user.plan.rawValue
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// Preview / テスト用。トークンを持たず、常に未ログインを返す。
public actor NoopAuthSessionController: AuthSessionController {
    public init() {}
    public func adoptSession(_ tokens: TokenPair) async {}
    public func clearSession() async {}
    public func restoreSession() async -> SessionRestoreResult { .signedOut }
    public func currentRefreshToken() async -> String? { nil }
    public func setSessionEndedHandler(_ handler: @escaping @Sendable () async -> Void) async {}
}
