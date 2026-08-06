import Foundation
import Security
import Core

/// Keychain 書き込みの結果判定。**失敗を握りつぶさない**（中-3）。
///
/// refresh token / 共有 token が保存できていないと
/// 「次回起動でサイレントログアウト」「共有ボードが一覧から消える」という形でしか現れず、
/// ログが無いと原因調査ができない。
///
/// `AppLogger` は本文を受け取れない設計（NFR-4）なので、
/// **固定イベント名 + `OSStatus`（値は秘密ではない）** だけを残す。
enum KeychainWrite {
    enum Operation: String {
        case update
        case add
        case delete
    }

    /// 記録すべき失敗イベント名。失敗でなければ nil。
    ///
    /// - `SecItemUpdate` の `errSecItemNotFound`: まだ項目が無いだけ（この後 `SecItemAdd` する）
    /// - `SecItemDelete` の `errSecItemNotFound`: 既に無い（clear は冪等）
    static func failureEvent(operation: Operation, status: OSStatus) -> String? {
        guard status != errSecSuccess else { return nil }
        if status == errSecItemNotFound, operation == .update || operation == .delete { return nil }
        return "keychain_\(operation.rawValue)_failed_\(status)"
    }

    /// 失敗なら記録する。
    static func log(_ logger: AppLogger, operation: Operation, status: OSStatus) {
        if let event = failureEvent(operation: operation, status: status) {
            logger.event(event)
        }
    }
}
