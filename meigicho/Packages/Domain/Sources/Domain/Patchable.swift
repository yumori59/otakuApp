import Foundation

/// PATCH の「送らない」と「`null` を送る」を型で区別する（`contract-mapping.md` §1.2）。
///
/// BE の PATCH は **送られたキーのみ更新**するため、この 2 つを取り違えると
/// 「消したつもりが消えない」「触っていない値が消える」が起きる。
public enum Patchable<T: Sendable>: Sendable {
    /// キーごと送らない（サーバー側の値を変更しない）
    case unchanged
    /// 値を送る。`nil` は **明示的な `null`**（クリア）
    case set(T?)

    public var isUnchanged: Bool {
        if case .unchanged = self { return true }
        return false
    }

    /// 変更後の値。`unchanged` なら現在値をそのまま返す。
    public func applied(to current: T?) -> T? {
        switch self {
        case .unchanged: current
        case .set(let value): value
        }
    }
}

extension Patchable: Equatable where T: Equatable {}

public extension KeyedEncodingContainer {
    /// `.unchanged` はキーごと省略し、`.set(nil)` は `null` を書く。
    mutating func encodePatch<T: Encodable & Sendable>(_ value: Patchable<T>, forKey key: Key) throws {
        switch value {
        case .unchanged:
            break
        case .set(let inner):
            if let inner {
                try encode(inner, forKey: key)
            } else {
                try encodeNil(forKey: key)
            }
        }
    }

    /// 値を変換してから書き出す版（`Date` → `"2026-08-20"` など）。
    mutating func encodePatch<T: Sendable, Encoded: Encodable>(
        _ value: Patchable<T>,
        forKey key: Key,
        transform: (T) -> Encoded
    ) throws {
        switch value {
        case .unchanged:
            break
        case .set(let inner):
            if let inner {
                try encode(transform(inner), forKey: key)
            } else {
                try encodeNil(forKey: key)
            }
        }
    }
}
