import Foundation
import os

/// `os.Logger` の薄いラッパー。
///
/// **メッセージ本文とトークンを受け取らない引数設計**にしてある（NFR-4）。
/// サーバーの `message` には個人情報が混ざりうるため、記録するのは
/// エラーコード・`request_id`・呼び出し元のカテゴリだけ。
public struct AppLogger: Sendable {
    private let logger: Logger

    public init(category: String) {
        self.logger = Logger(subsystem: "jp.meigicho.app", category: category)
    }

    /// API エラーの記録。**`message` / トークン / token 付き URL は渡せない。**
    public func error(code: String, requestID: String?) {
        logger.error("api_error code=\(code, privacy: .public) request_id=\(requestID ?? "-", privacy: .public)")
    }

    /// 未知の生値を既定値にフォールバックした事実の記録（BE-2 の iOS 版）。
    public func unknownValue(field: String, rawValue: String) {
        logger.notice("unknown_value field=\(field, privacy: .public) raw=\(rawValue, privacy: .public)")
    }

    /// 開発時の到達確認（本文を持たない固定イベント名のみ）。
    public func event(_ name: String) {
        logger.debug("event=\(name, privacy: .public)")
    }
}
