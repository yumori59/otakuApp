import Foundation
import Core
import Domain

// `contract-mapping.md` §4.1。
// **`keyDecodingStrategy` を使わず CodingKeys を明示する**（§1.1）。
// リクエストとレスポンスは別型（1 型を双方向に使わない）。

// MARK: - Response

/// `POST /v1/auth/{apple,google,register,login,password/reset}` の 200/201。**4 経路とも同形**。
struct AuthSessionResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String
    let user: AuthUserResponse

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case user
    }
}

/// `AuthSessionResponse.user`。**`account_id` / `display_name` は null がありうる**（AC-AUTH-01-T）。
struct AuthUserResponse: Decodable, Sendable {
    let id: UUID
    let accountID: String?
    let displayName: String?
    let plan: String
    let isNew: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case accountID = "account_id"
        case displayName = "display_name"
        case plan
        case isNew = "is_new"
    }
}

/// `POST /v1/auth/refresh` / `POST /v1/auth/password` の 200（user を含まない）。
struct TokenPairResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
    }
}

// MARK: - Request

/// **Apple は `identity_token`**（Google の `id_token` と取り違えない — A1 / AC-GG-07）。
struct AppleSignInRequest: Encodable, Sendable {
    let identityToken: String
    /// 認可リクエストに設定したのと**同じ文字列**。sha256 しない（A2 / Q4）
    let nonce: String?

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case nonce
    }
}

/// **Google は `id_token`**（Apple の `identity_token` と取り違えない — A1 / AC-GG-07）。
struct GoogleSignInRequest: Encodable, Sendable {
    /// Google が返した JWT を**加工せず**そのまま
    let idToken: String
    /// 認可リクエストの `nonce` と同じ文字列。sha256 しない（A2）
    let nonce: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case nonce
    }
}

struct RefreshRequest: Encodable, Sendable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

struct LogoutRequest: Encodable, Sendable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

// MARK: - Domain へのマッピング

/// トークンの有効期限には **60 秒のマージン**を引く（`contract-mapping.md` §4.1）。
/// 期限前でも 401 は起こりうるので、`ApiClient` の 401 再送は必ず残す。
enum TokenExpiry {
    static let marginSeconds: TimeInterval = 60

    static func expiresAt(expiresIn: Int, receivedAt: Date) -> Date {
        receivedAt.addingTimeInterval(max(TimeInterval(expiresIn) - marginSeconds, 0))
    }
}

extension TokenPairResponse {
    func toDomain(receivedAt: Date) -> TokenPair {
        TokenPair(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: TokenExpiry.expiresAt(expiresIn: expiresIn, receivedAt: receivedAt)
        )
    }
}

extension AuthSessionResponse {
    func toDomain(receivedAt: Date) -> AuthSession {
        AuthSession(
            tokens: TokenPair(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: TokenExpiry.expiresAt(expiresIn: expiresIn, receivedAt: receivedAt)
            ),
            user: user.toDomain()
        )
    }
}

extension AuthUserResponse {
    func toDomain() -> SignedInUser {
        SignedInUser(
            id: id,
            accountID: accountID,
            displayName: displayName,
            plan: Self.plan(from: plan),
            isNew: isNew
        )
    }

    /// 未知の plan でログインを失敗させない。**フォールバックした事実はログに残す**（BE-2 の iOS 版）。
    private static func plan(from raw: String) -> Plan {
        guard let plan = Plan(rawValue: raw) else {
            AppLogger(category: "auth").unknownValue(field: "plan", rawValue: raw)
            return .free
        }
        return plan
    }
}
