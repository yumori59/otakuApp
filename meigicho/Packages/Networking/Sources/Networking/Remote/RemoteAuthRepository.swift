import Foundation
import Core
import Domain

/// `AuthRepository` の HTTP 実装（`contract-mapping.md` §4.1）。
///
/// `/v1/auth/*` は **`/v1` プレフィックスを持つが Public**（`POST /v1/auth/password` を除く）。
/// そのため `authorization: .none` で送る。**サインイン失敗の 401 で refresh を走らせない**ため
/// （`AUTH_APPLE_INVALID` / `AUTH_GOOGLE_INVALID` は復帰不能で、再送しても同じ結果になる）。
public struct RemoteAuthRepository: AuthRepository {
    private let client: ApiClient
    private let now: @Sendable () -> Date

    public init(client: ApiClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
    }

    // MARK: - ソーシャル

    public func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthSession {
        // **Apple のキーは `identity_token`**（A1）
        let body = try JSONEncoder().encode(AppleSignInRequest(identityToken: identityToken, nonce: nonce))
        let response = try await client.send(
            .versioned(.post, "/auth/apple", body: body),
            as: AuthSessionResponse.self,
            authorization: .none
        )
        return response.toDomain(receivedAt: now())
    }

    public func signInWithGoogle(idToken: String, nonce: String?) async throws -> AuthSession {
        // **Google のキーは `id_token`**（A1）。値は加工しない（AC-GG-07）
        let body = try JSONEncoder().encode(GoogleSignInRequest(idToken: idToken, nonce: nonce))
        let response = try await client.send(
            .versioned(.post, "/auth/google", body: body),
            as: AuthSessionResponse.self,
            authorization: .none
        )
        return response.toDomain(receivedAt: now())
    }

    // MARK: - トークン

    /// 回転式。呼び出し側は返ってきた `refreshToken` を必ず保存し直す。
    ///
    /// なお **通常の 401 自動 refresh は `ApiClient` が内部で完結させる**（ここは経由しない）。
    public func refresh(refreshToken: String) async throws -> TokenPair {
        let body = try JSONEncoder().encode(RefreshRequest(refreshToken: refreshToken))
        let response = try await client.send(
            .versioned(.post, "/auth/refresh", body: body),
            as: TokenPairResponse.self,
            authorization: .none
        )
        return response.toDomain(receivedAt: now())
    }

    public func logout(refreshToken: String) async throws {
        let body = try JSONEncoder().encode(LogoutRequest(refreshToken: refreshToken))
        try await client.sendVoid(
            .versioned(.post, "/auth/logout", body: body),
            authorization: .none
        )
    }

    // MARK: - メール + パスワード

    // 契約は `contract-mapping.md` §4.1（A3〜A11）と `api-contract-delta.md` §1。
    // **`password` / `password/reset` は成功時にサーバーが refresh を全件失効させ新しいペアを返す**ので、
    // 呼び出し側（`AuthStore`）は戻り値を捨てずに `AuthSessionController.adoptSession` で上書きする（A5 / A6 / R9）。

    /// **201 Created**（`login` / `password/reset` は 200 — A3）。
    /// `ResponseValidator` は 2xx を一律で通すため、iOS 側でステータスコードによる分岐はしない。
    public func register(email: String, password: String) async throws -> AuthSession {
        let body = try JSONEncoder().encode(RegisterRequest(email: email, password: password))
        let response = try await client.send(
            .versioned(.post, "/auth/register", body: body),
            as: AuthSessionResponse.self,
            authorization: .none
        )
        return response.toDomain(receivedAt: now())
    }

    /// 401 は `AUTH_CREDENTIALS_INVALID`。**未登録 / パスワード誤り / パスワード未設定を区別しない**（A7）。
    public func login(email: String, password: String) async throws -> AuthSession {
        let body = try JSONEncoder().encode(LoginRequest(email: email, password: password))
        let response = try await client.send(
            .versioned(.post, "/auth/login", body: body),
            as: AuthSessionResponse.self,
            authorization: .none
        )
        return response.toDomain(receivedAt: now())
    }

    /// **メール系で唯一 Bearer 必須**（A5）。
    ///
    /// `AUTH_CREDENTIALS_INVALID` 401 は `ApiClient` の 401 refresh 経路に入らない
    /// （`.unauthenticated` だけが再送対象）。`current_password` 誤りで自分のセッションを巻き込まない。
    public func changePassword(current: String, new: String) async throws -> TokenPair {
        let body = try JSONEncoder().encode(
            ChangePasswordRequest(currentPassword: current, newPassword: new)
        )
        let response = try await client.send(
            .versioned(.post, "/auth/password", body: body),
            as: TokenPairResponse.self,
            authorization: .bearer
        )
        return response.toDomain(receivedAt: now())
    }

    /// **202 / ボディ無し**。登録の有無に関わらず常に同じ応答なので、成功しても存在を断定しない（A4）。
    public func requestPasswordReset(email: String) async throws {
        let body = try JSONEncoder().encode(ResetRequestRequest(email: email))
        try await client.sendVoid(
            .versioned(.post, "/auth/password/reset-request", body: body),
            authorization: .none
        )
    }

    /// 成功時は全件失効 + 新ペア。**そのままログイン状態にする**（A6）。
    public func resetPassword(email: String, code: String, newPassword: String) async throws -> AuthSession {
        let body = try JSONEncoder().encode(
            ResetPasswordRequest(email: email, code: code, newPassword: newPassword)
        )
        let response = try await client.send(
            .versioned(.post, "/auth/password/reset", body: body),
            as: AuthSessionResponse.self,
            authorization: .none
        )
        return response.toDomain(receivedAt: now())
    }

    // MARK: - アカウント削除

    /// `DELETE /v1/me`。**Bearer 必須**。204（body 無し）。
    /// 契約は `account-deletion/api-contract-delta.md` §1・§3.2。
    public func deleteAccount(password: String?, appleAuthorizationCode: String?) async throws {
        let body = try JSONEncoder().encode(
            DeleteAccountRequest(password: password, appleAuthorizationCode: appleAuthorizationCode)
        )
        try await client.sendVoid(.versioned(.delete, "/me", body: body))
    }
}
