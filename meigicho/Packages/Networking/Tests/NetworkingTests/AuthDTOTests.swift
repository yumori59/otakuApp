import XCTest
import Domain
@testable import Networking

/// `contract-mapping.md` §4.1 の DTO 契約。
final class AuthDTOTests: XCTestCase {
    private let decoder = JSONDecoder()

    /// AC-AUTH-01-T: `account_id` / `display_name` が null でもデコードに失敗しない
    func testAuthSessionDecodesWithNullAccountIDAndDisplayName() throws {
        let json = """
        {
          "access_token": "at",
          "refresh_token": "rt",
          "expires_in": 3600,
          "token_type": "Bearer",
          "user": {
            "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
            "account_id": null,
            "display_name": null,
            "plan": "free",
            "is_new": true
          }
        }
        """
        let response = try decoder.decode(AuthSessionResponse.self, from: Data(json.utf8))
        let session = response.toDomain(receivedAt: Date())

        XCTAssertNil(session.user.accountID)
        XCTAssertNil(session.user.displayName)
        XCTAssertEqual(session.user.plan, .free)
        XCTAssertTrue(session.user.isNew)
        XCTAssertEqual(session.accessToken, "at")
        XCTAssertEqual(session.refreshToken, "rt")
    }

    func testAuthSessionDecodesServerIssuedAccountID() throws {
        let json = """
        {
          "access_token": "at", "refresh_token": "rt", "expires_in": 3600, "token_type": "Bearer",
          "user": { "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f", "account_id": "ACC-3F9A21",
                    "display_name": "でんちゃん", "plan": "plus", "is_new": false }
        }
        """
        let session = try decoder.decode(AuthSessionResponse.self, from: Data(json.utf8)).toDomain(receivedAt: Date())
        XCTAssertEqual(session.user.accountID, "ACC-3F9A21")
        XCTAssertEqual(session.user.plan, .plus)
    }

    /// 未知の plan でログインを落とさない（BE-2 の iOS 版）
    func testUnknownPlanFallsBackToFree() throws {
        let json = """
        {
          "access_token": "at", "refresh_token": "rt", "expires_in": 3600, "token_type": "Bearer",
          "user": { "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f", "account_id": "ACC-000001",
                    "display_name": null, "plan": "enterprise", "is_new": false }
        }
        """
        let session = try decoder.decode(AuthSessionResponse.self, from: Data(json.utf8)).toDomain(receivedAt: Date())
        XCTAssertEqual(session.user.plan, .free)
    }

    /// AC-AUTH-02-T: `expires_in: 3600` → 受信時刻 + 3540 秒（60 秒マージン）
    func testExpiresAtHasSixtySecondMargin() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        { "access_token": "at", "refresh_token": "rt", "expires_in": 3600, "token_type": "Bearer" }
        """
        let pair = try decoder.decode(TokenPairResponse.self, from: Data(json.utf8)).toDomain(receivedAt: receivedAt)
        XCTAssertEqual(pair.expiresAt, receivedAt.addingTimeInterval(3540))
    }

    /// マージンを引いて負にならない
    func testShortExpiryDoesNotGoNegative() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
        { "access_token": "at", "refresh_token": "rt", "expires_in": 10, "token_type": "Bearer" }
        """
        let pair = try decoder.decode(TokenPairResponse.self, from: Data(json.utf8)).toDomain(receivedAt: receivedAt)
        XCTAssertEqual(pair.expiresAt, receivedAt)
    }

    /// AC-GG-07: Apple は `identity_token`、Google は `id_token`。**キー名を取り違えない**
    func testRequestKeysDifferBetweenAppleAndGoogle() throws {
        let apple = try JSONEncoder().encode(AppleSignInRequest(identityToken: "APPLE_JWT", nonce: "N1"))
        let appleObject = try XCTUnwrap(JSONSerialization.jsonObject(with: apple) as? [String: Any])
        XCTAssertEqual(appleObject["identity_token"] as? String, "APPLE_JWT")
        XCTAssertEqual(appleObject["nonce"] as? String, "N1")
        XCTAssertNil(appleObject["id_token"])

        let google = try JSONEncoder().encode(GoogleSignInRequest(idToken: "GOOGLE_JWT", nonce: "N2"))
        let googleObject = try XCTUnwrap(JSONSerialization.jsonObject(with: google) as? [String: Any])
        XCTAssertEqual(googleObject["id_token"] as? String, "GOOGLE_JWT")
        XCTAssertEqual(googleObject["nonce"] as? String, "N2")
        XCTAssertNil(googleObject["identity_token"])
    }

    /// nonce 省略時はキーごと出さない（サーバーは送られたときだけ検証する）
    func testNonceIsOmittedWhenNil() throws {
        let data = try JSONEncoder().encode(GoogleSignInRequest(idToken: "GOOGLE_JWT", nonce: nil))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["nonce"])
    }

    func testRefreshAndLogoutUseSnakeCaseKey() throws {
        let refresh = try JSONEncoder().encode(RefreshRequest(refreshToken: "rt"))
        XCTAssertEqual(String(data: refresh, encoding: .utf8), #"{"refresh_token":"rt"}"#)
        let logout = try JSONEncoder().encode(LogoutRequest(refreshToken: "rt"))
        XCTAssertEqual(String(data: logout, encoding: .utf8), #"{"refresh_token":"rt"}"#)
    }
}
