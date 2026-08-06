import Foundation
import CryptoKit

/// RFC 7636 (PKCE) の純関数。Google の認可フロー（`plan.md` §7.2）で使う。
public enum PKCE {
    /// `code_verifier`: 43〜128 文字の unreserved 文字列。
    /// 32 byte 乱数の base64url = 43 文字。
    public static func generateCodeVerifier(byteCount: Int = 32) -> String {
        Base64URL.encode(Nonce.randomBytes(count: byteCount))
    }

    /// `code_challenge = base64url(SHA256(code_verifier))`（`code_challenge_method=S256`）。
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Base64URL.encode(Data(digest))
    }
}
