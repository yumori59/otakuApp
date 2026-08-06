import XCTest
import Domain
@testable import Network

/// メール + パスワード 5 経路の DTO 契約（`contract-mapping.md` §4.1 / AC-EM-01）。
final class AuthEmailDTOTests: XCTestCase {
    private func object(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// AC-EM-01: JSON キーは `email` / `password` / `code` / `new_password`
    func testRegisterAndLoginKeys() throws {
        let register = try object(RegisterRequest(email: "fan@example.com", password: "correct horse"))
        XCTAssertEqual(register["email"] as? String, "fan@example.com")
        XCTAssertEqual(register["password"] as? String, "correct horse")
        XCTAssertEqual(register.count, 2)

        let login = try object(LoginRequest(email: "fan@example.com", password: "correct horse"))
        XCTAssertEqual(login["email"] as? String, "fan@example.com")
        XCTAssertEqual(login["password"] as? String, "correct horse")
        XCTAssertEqual(login.count, 2)
    }

    func testChangePasswordUsesSnakeCaseKeys() throws {
        let body = try object(ChangePasswordRequest(currentPassword: "old one", newPassword: "a brand new one"))
        XCTAssertEqual(body["current_password"] as? String, "old one")
        XCTAssertEqual(body["new_password"] as? String, "a brand new one")
        // camelCase が漏れていない（`keyEncodingStrategy` を使わないため CodingKeys が唯一の正）
        XCTAssertNil(body["currentPassword"])
        XCTAssertNil(body["newPassword"])
        XCTAssertEqual(body.count, 2)
    }

    func testResetRequestSendsOnlyEmail() throws {
        let body = try object(ResetRequestRequest(email: "fan@example.com"))
        XCTAssertEqual(body["email"] as? String, "fan@example.com")
        XCTAssertEqual(body.count, 1)
    }

    func testResetPasswordKeys() throws {
        let body = try object(ResetPasswordRequest(email: "fan@example.com", code: "48210937", newPassword: "a brand new one"))
        XCTAssertEqual(body["email"] as? String, "fan@example.com")
        XCTAssertEqual(body["code"] as? String, "48210937")
        XCTAssertEqual(body["new_password"] as? String, "a brand new one")
        XCTAssertEqual(body.count, 3)
    }

    /// `register` / `login` / `password/reset` のレスポンスは Apple / Google と**完全に同形**（§4.1）。
    /// 型を分けていないことをデコードで確かめる
    func testEmailRoutesShareTheSameSessionResponse() throws {
        let json = """
        {
          "access_token": "at", "refresh_token": "rt", "expires_in": 3600, "token_type": "Bearer",
          "user": { "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f", "account_id": "ACC-7C21A0",
                    "display_name": null, "plan": "free", "is_new": true }
        }
        """
        let session = try JSONDecoder().decode(AuthSessionResponse.self, from: Data(json.utf8)).toDomain(receivedAt: Date())
        XCTAssertEqual(session.user.accountID, "ACC-7C21A0")
        XCTAssertTrue(session.user.isNew)
    }

    /// `POST /v1/auth/password` は user を含まない `TokenPairResponse`（`refresh` と同形）
    func testChangePasswordResponseHasNoUser() throws {
        let json = """
        { "access_token": "at", "refresh_token": "new-rt", "expires_in": 3600, "token_type": "Bearer" }
        """
        let pair = try JSONDecoder().decode(TokenPairResponse.self, from: Data(json.utf8)).toDomain(receivedAt: Date())
        XCTAssertEqual(pair.refreshToken, "new-rt")
    }

    /// AC-AD-04-M: `DeleteAccountRequest` は両方渡すと 2 キーとも snake_case で送る
    func testDeleteAccountRequestSendsBothKeys() throws {
        let body = try object(DeleteAccountRequest(password: "correct horse", appleAuthorizationCode: "c1a2b3"))
        XCTAssertEqual(body["password"] as? String, "correct horse")
        XCTAssertEqual(body["apple_authorization_code"] as? String, "c1a2b3")
        XCTAssertEqual(body.count, 2)
    }

    /// AC-AD-04-M: `nil` は `encodeIfPresent` によりキーごと省略される（両方 nil なら `{}`）
    func testDeleteAccountRequestOmitsNilKeys() throws {
        let body = try object(DeleteAccountRequest(password: nil, appleAuthorizationCode: nil))
        XCTAssertTrue(body.isEmpty)
    }

    /// AC-EM-02: エラーコードが専用ケースに写る（既知ケースへ丸めない）
    func testEmailErrorCodesMapToDedicatedCases() {
        XCTAssertEqual(AppError.from(envelope: APIErrorEnvelope(code: "AUTH_CREDENTIALS_INVALID")), .credentialsInvalid)
        XCTAssertEqual(AppError.from(envelope: APIErrorEnvelope(code: "EMAIL_ALREADY_REGISTERED")), .emailAlreadyRegistered)
        XCTAssertEqual(AppError.from(envelope: APIErrorEnvelope(code: "AUTH_RESET_CODE_INVALID")), .resetCodeInvalid)
        XCTAssertEqual(AppError.from(envelope: APIErrorEnvelope(code: "RATE_LIMITED")), .rateLimited)
        // `EMAIL_ALREADY_REGISTERED` を汎用 `CONFLICT` に丸めない
        XCTAssertNotEqual(AppError.from(envelope: APIErrorEnvelope(code: "EMAIL_ALREADY_REGISTERED")), .conflict)
    }
}
