import Foundation
import Security
import Core

/// refresh token の保管（`questions-requirements.md` Q6）。
///
/// - **refresh token だけ**を保管する。access token はメモリのみ（`ApiClient`）
/// - 共有ボードの token は**別 service 名前空間**で `SharedBoardTokenStore`（T4b）が持つ。ここに混ぜない
/// - 値をログに出さない（`AppLogger` は `code` / `requestID` しか受け取れない）
public protocol RefreshTokenStoring: Sendable {
    func read() async -> String?
    func write(_ token: String) async
    func clear() async
}

/// Keychain 実装（`Security` フレームワーク直叩き。第三者ライブラリを足さない）。
///
/// `kSecAttrAccessibleAfterFirstUnlock`: 再起動後の最初のアンロック以降に読める。
/// バックグラウンドでの自動 refresh を成立させるためロック中に読めない設定は使わない。
public struct KeychainTokenStore: RefreshTokenStoring {
    private let service: String
    private let account: String
    /// 書き込み失敗を握りつぶさない（固定イベント名 + OSStatus のみ。値は残さない）
    private let logger = AppLogger(category: "auth")

    public init(service: String = "jp.meigicho.app.auth", account: String = "refresh_token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() async -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ token: String) async {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            // 保存できていないと次回起動でサイレントログアウトになる。失敗は必ず記録する
            KeychainWrite.log(logger, operation: .add, status: SecItemAdd(insert as CFDictionary, nil))
        } else {
            KeychainWrite.log(logger, operation: .update, status: status)
        }
    }

    public func clear() async {
        KeychainWrite.log(logger, operation: .delete, status: SecItemDelete(baseQuery as CFDictionary))
    }
}

/// テスト / Preview / UI テスト用。**Keychain に触らない**。
public actor InMemoryTokenStore: RefreshTokenStoring {
    private var token: String?

    public init(token: String? = nil) {
        self.token = token
    }

    public func read() async -> String? { token }
    public func write(_ token: String) async { self.token = token }
    public func clear() async { token = nil }
}
