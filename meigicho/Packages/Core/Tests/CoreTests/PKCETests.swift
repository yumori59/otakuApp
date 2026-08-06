import XCTest
@testable import Core

/// AC-N-11-T: RFC 7636 Appendix B の既知ベクタと一致する
final class PKCETests: XCTestCase {
    func testChallengeMatchesRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierIsBase64URLAndWithinLengthBounds() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for _ in 0..<50 {
            let verifier = PKCE.generateCodeVerifier()
            XCTAssertGreaterThanOrEqual(verifier.count, 43)
            XCTAssertLessThanOrEqual(verifier.count, 128)
            XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) }, "unexpected char in \(verifier)")
        }
    }

    func testGeneratedVerifiersAreUnique() {
        let values = Set((0..<100).map { _ in PKCE.generateCodeVerifier() })
        XCTAssertEqual(values.count, 100)
    }

    func testChallengeIsBase64URLWithoutPadding() {
        let challenge = PKCE.challenge(for: PKCE.generateCodeVerifier())
        XCTAssertEqual(challenge.count, 43)
        XCTAssertFalse(challenge.contains("="))
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
    }
}

final class NonceTests: XCTestCase {
    func testNonceIsBase64URLWithoutPadding() {
        for _ in 0..<50 {
            let nonce = Nonce.generate()
            XCTAssertFalse(nonce.isEmpty)
            XCTAssertFalse(nonce.contains("="))
            XCTAssertFalse(nonce.contains("+"))
            XCTAssertFalse(nonce.contains("/"))
        }
    }

    func testNoncesAreUnique() {
        let values = Set((0..<100).map { _ in Nonce.generate() })
        XCTAssertEqual(values.count, 100)
    }
}
