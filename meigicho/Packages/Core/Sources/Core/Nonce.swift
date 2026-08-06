import Foundation
import Security

/// 認可リクエスト用の nonce（Apple / Google の両方で使う）。
///
/// BE は **平文比較**する（`contract-mapping.md` §4.1 A2）。
/// ここで作った文字列をそのまま認可リクエストに載せ、同じ文字列を BE に送ること。
public enum Nonce {
    /// 32 byte の乱数を base64url（パディング無し）で返す。
    public static func generate(byteCount: Int = 32) -> String {
        Base64URL.encode(randomBytes(count: byteCount))
    }

    static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            // SecRandomCopyBytes が失敗する状況は想定外。暗号品質の乱数にフォールバックする。
            var rng = SystemRandomNumberGenerator()
            return (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
        }
        return bytes
    }
}

/// base64url（`+` → `-` / `/` → `_` / パディング除去）。
public enum Base64URL {
    public static func encode(_ bytes: [UInt8]) -> String {
        encode(Data(bytes))
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
