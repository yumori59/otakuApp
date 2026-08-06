import Foundation

// メール + パスワード 5 経路のリクエスト DTO（`contract-mapping.md` §4.1 / `api-contract-delta.md` §1）。
//
// レスポンスは `AuthDTO.swift` の `AuthSessionResponse` / `TokenPairResponse` を共用する。
// `register` / `login` / `password/reset` は Apple / Google と**完全に同形**なので型を増やさない。
// **`keyDecodingStrategy` / `keyEncodingStrategy` を使わず `CodingKeys` を明示する**（§1.1）。

/// `POST /v1/auth/register` — Public。**201**（他は 200 — A3）。
struct RegisterRequest: Encodable, Sendable {
    /// trim だけして送る。正規化（小文字化）は**サーバーがやる**（A10）
    let email: String
    /// 8〜128 文字。**文字種要件は無い**（A9 / IOS-4）
    let password: String
}

/// `POST /v1/auth/login` — Public。
/// 401 は未登録 / パスワード誤り / パスワード未設定を**区別しない**（A7）。
struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String
}

/// `POST /v1/auth/password` — **Bearer 必須**（メール系で唯一）。
///
/// 成功時にサーバーがその user の refresh token を全件失効させ、新しいペアを返す。
/// 呼び出し側は返ってきたペアで Keychain を必ず上書きする（A5 / R9）。
struct ChangePasswordRequest: Encodable, Sendable {
    let currentPassword: String
    let newPassword: String

    enum CodingKeys: String, CodingKey {
        case currentPassword = "current_password"
        case newPassword = "new_password"
    }
}

/// `POST /v1/auth/password/reset-request` — Public。**202 / ボディ無し**（A4）。
/// 登録の有無に関わらず同じ応答になるため、UI は「登録されていれば送信しました」と書く。
struct ResetRequestRequest: Encodable, Sendable {
    let email: String
}

/// `POST /v1/auth/password/reset` — Public。成功時は全件失効 + 新ペア（A6）。
struct ResetPasswordRequest: Encodable, Sendable {
    let email: String
    /// **8 桁の数字**（`^\d{8}$` — A8）
    let code: String
    let newPassword: String

    enum CodingKeys: String, CodingKey {
        case email
        case code
        case newPassword = "new_password"
    }
}

/// `DELETE /v1/me` — Bearer 必須（`account-deletion/api-contract-delta.md` §3.2）。
/// 両フィールドとも任意。`nil` は `encodeIfPresent` によりキー自体が省略される
/// （`keyEncodingStrategy` は使わない — §1.1）。両方 nil のときは `{}` を送ってよい。
struct DeleteAccountRequest: Encodable, Sendable {
    let password: String?
    let appleAuthorizationCode: String?

    enum CodingKeys: String, CodingKey {
        case password
        case appleAuthorizationCode = "apple_authorization_code"
    }
}
