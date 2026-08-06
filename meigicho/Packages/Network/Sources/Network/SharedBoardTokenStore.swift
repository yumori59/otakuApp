import Foundation
import Security
import CryptoKit
import Core
import Domain

/// 受け取った共有 token の保管（`contract-mapping.md` §5.1）。
///
/// - token は「そのボードを読み書きできる」capability。**UserDefaults に置かない**
///   （平文で iCloud バックアップに載る）
/// - **自分の refresh token（`KeychainTokenStore` / service `jp.meigicho.app.auth`）とは
///   別 service 名前空間**。ライフサイクルが違う（回転しない・失効はサーバー都合・複数本を同時に持ちうる）
/// - 保存するのは `token` と表示用の最小メタ（ツアー名・最終取得時刻）だけ。
///   **サーバーから来た表データはキャッシュしない**
/// - `SHARE_INVALID` を受けたらその token を破棄する（`SharedBoardStore` が呼ぶ）
/// - 値をログに出さない（`AppLogger` は `code` / `requestID` / 固定イベント名しか受け取れない）
public struct KeychainSharedBoardTokenStore: SharedBoardTokenStoring {
    /// **`KeychainTokenStore` の `jp.meigicho.app.auth` とは別**。混ぜない
    private let service: String
    /// 書き込み失敗を握りつぶさない（固定イベント名 + OSStatus のみ。token は残さない）
    private let logger = AppLogger(category: "shared-board")

    public init(service: String = "jp.meigicho.app.sharedboard") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    /// account 属性には token をそのまま入れない（属性は本文ほど強く保護されない）。
    /// SHA-256 の hex を安定キーにして、token 本体は value data 側に置く。
    private func accountKey(for token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func list() async -> [SavedSharedBoard] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        guard status == errSecSuccess, let rows = items as? [Data] else { return [] }

        let decoder = JSONDecoder()
        return rows
            .compactMap { try? decoder.decode(SavedSharedBoard.self, from: $0) }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    public func save(_ board: SavedSharedBoard) async {
        guard let data = try? JSONEncoder().encode(board) else {
            logger.event("shared_board_token_encode_failed")
            return
        }
        var query = baseQuery
        query[kSecAttrAccount as String] = accountKey(for: board.token)

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            KeychainWrite.log(logger, operation: .add, status: SecItemAdd(insert as CFDictionary, nil))
        } else {
            KeychainWrite.log(logger, operation: .update, status: status)
        }
    }

    public func remove(token: String) async {
        var query = baseQuery
        query[kSecAttrAccount as String] = accountKey(for: token)
        KeychainWrite.log(logger, operation: .delete, status: SecItemDelete(query as CFDictionary))
    }
}

/// テスト / Preview / UI テスト用。**Keychain に触らない**。
public actor InMemorySharedBoardTokenStore: SharedBoardTokenStoring {
    private var boards: [String: SavedSharedBoard]

    public init(boards: [SavedSharedBoard] = []) {
        self.boards = Dictionary(uniqueKeysWithValues: boards.map { ($0.token, $0) })
    }

    public func list() async -> [SavedSharedBoard] {
        boards.values.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    public func save(_ board: SavedSharedBoard) async {
        boards[board.token] = board
    }

    public func remove(token: String) async {
        boards[token] = nil
    }
}
