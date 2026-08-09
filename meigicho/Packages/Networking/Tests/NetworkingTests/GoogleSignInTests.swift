import XCTest
import Core
import Domain
@testable import Networking

/// `plan.md` §7.2.1 の純関数部分（AC-GG-01-T / AC-GG-02-T）。
final class GoogleSignInTests: XCTestCase {
    private let clientID = "1234567890-abcdef.apps.googleusercontent.com"
    private let reversed = "com.googleusercontent.apps.1234567890-abcdef"

    private func makeRequest() throws -> GoogleAuthorizationRequest {
        try XCTUnwrap(GoogleAuthorizationRequest(
            clientID: clientID,
            codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            nonce: "NONCE-123",
            state: "STATE-456"
        ))
    }

    func testReversedClientID() {
        XCTAssertEqual(GoogleAuthorizationRequest.reversedClientID(from: clientID), reversed)
        XCTAssertNil(GoogleAuthorizationRequest.reversedClientID(from: "not-a-google-client-id"))
        XCTAssertNil(GoogleAuthorizationRequest.reversedClientID(from: ".apps.googleusercontent.com"))
    }

    func testRedirectURIUsesReversedClientIDScheme() throws {
        let request = try makeRequest()
        XCTAssertEqual(request.callbackScheme, reversed)
        XCTAssertEqual(request.redirectURI, "\(reversed):/oauth2redirect")
    }

    /// AC-GG-01-T: 認可 URL に必須パラメータが全部入る
    func testAuthorizationURLContainsAllRequiredParameters() throws {
        let request = try makeRequest()
        let components = try XCTUnwrap(URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.host, "accounts.google.com")
        XCTAssertEqual(components.path, "/o/oauth2/v2/auth")
        XCTAssertEqual(items["client_id"], clientID)
        XCTAssertEqual(items["redirect_uri"], "\(reversed):/oauth2redirect")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "openid email profile")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["nonce"], "NONCE-123")
        XCTAssertEqual(items["state"], "STATE-456")
        // RFC 7636 の既知ベクタ（AC-N-11-T と同じ verifier）
        XCTAssertEqual(items["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        // 認可 URL に client_secret を載せない
        XCTAssertNil(items["client_secret"])
    }

    /// **nonce は sha256 しない**（A2 / Q4）。認可 URL の値と BE に送る値が同じであること
    func testNonceSentToBackendMatchesAuthorizationParameter() throws {
        let request = try makeRequest()
        let items = URLComponents(url: request.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let urlNonce = items.first { $0.name == "nonce" }?.value
        XCTAssertEqual(urlNonce, request.nonce)
        XCTAssertNotEqual(request.nonce, PKCE.challenge(for: request.nonce))
    }

    func testGeneratedRequestUsesFreshRandomValues() throws {
        let a = try XCTUnwrap(GoogleAuthorizationRequest(clientID: clientID))
        let b = try XCTUnwrap(GoogleAuthorizationRequest(clientID: clientID))
        XCTAssertNotEqual(a.codeVerifier, b.codeVerifier)
        XCTAssertNotEqual(a.nonce, b.nonce)
        XCTAssertNotEqual(a.state, b.state)
        XCTAssertEqual(a.codeChallenge, PKCE.challenge(for: a.codeVerifier))
    }

    // MARK: - コールバック解析（AC-GG-02-T）

    func testCallbackReturnsCode() throws {
        let url = URL(string: "\(reversed):/oauth2redirect?code=AUTH_CODE&state=STATE-456")!
        XCTAssertEqual(try GoogleAuthorizationRequest.parseCallback(url, expectedState: "STATE-456"), .code("AUTH_CODE"))
    }

    func testCallbackRejectsStateMismatch() {
        let url = URL(string: "\(reversed):/oauth2redirect?code=AUTH_CODE&state=ATTACKER")!
        XCTAssertThrowsError(try GoogleAuthorizationRequest.parseCallback(url, expectedState: "STATE-456")) { error in
            XCTAssertEqual(error as? AppError, .googleSignInFailed)
        }
    }

    func testCallbackRejectsMissingState() {
        let url = URL(string: "\(reversed):/oauth2redirect?code=AUTH_CODE")!
        XCTAssertThrowsError(try GoogleAuthorizationRequest.parseCallback(url, expectedState: "STATE-456"))
    }

    /// `access_denied` は**ユーザーキャンセル**。エラーにしない（E-14）
    func testAccessDeniedIsTreatedAsCancellation() throws {
        let url = URL(string: "\(reversed):/oauth2redirect?error=access_denied&state=STATE-456")!
        XCTAssertEqual(try GoogleAuthorizationRequest.parseCallback(url, expectedState: "STATE-456"), .cancelled)
    }

    func testOtherErrorsFail() {
        let url = URL(string: "\(reversed):/oauth2redirect?error=invalid_request&state=STATE-456")!
        XCTAssertThrowsError(try GoogleAuthorizationRequest.parseCallback(url, expectedState: "STATE-456"))
    }

    func testEmptyCodeFails() {
        let url = URL(string: "\(reversed):/oauth2redirect?code=&state=STATE-456")!
        XCTAssertThrowsError(try GoogleAuthorizationRequest.parseCallback(url, expectedState: "STATE-456"))
    }

    // MARK: - トークン交換のボディ

    /// `application/x-www-form-urlencoded`。**client_secret を含めない**
    func testFormURLEncodedBody() {
        let body = GoogleAuthorizationRequest.formURLEncoded([
            ("code", "4/0Ab_c-d+e"),
            ("client_id", clientID),
            ("grant_type", "authorization_code"),
        ])
        XCTAssertTrue(body.contains("code=4%2F0Ab_c-d%2Be"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testTokenResponseDecodesIdTokenOnly() throws {
        let json = """
        { "access_token": "AT", "expires_in": 3599, "id_token": "GOOGLE_JWT", "scope": "openid", "token_type": "Bearer" }
        """
        let response = try JSONDecoder().decode(GoogleTokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.idToken, "GOOGLE_JWT")
    }

    /// `GOOGLE_IOS_CLIENT_ID` 未設定なら nil（ボタンは出すが実行させない）
    func testMakeFromBundleReturnsNilWithoutClientID() {
        XCTAssertNil(GoogleSignInService.makeFromBundle(Bundle(for: GoogleSignInTests.self)))
    }
}
