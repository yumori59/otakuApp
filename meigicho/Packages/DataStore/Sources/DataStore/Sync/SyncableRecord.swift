import Foundation
import SwiftData
import Domain
import Core

/// 同期対象のローカル行が満たす契約（`docs/04` §4 / `docs/05` §5）。
/// `#Predicate` は具象型でしか書けないので、fetch 系は各 `@Model` 側で実装する。
public protocol SyncableRecord: AnyObject, PersistentModel {
    static var syncCollection: SyncCollection { get }
    /// `syncState != .synced` の行（push 対象）。
    static func fetchPending(in context: ModelContext) throws -> [Self]
    static func fetchRecord(id: UUID, in context: ModelContext) throws -> Self?
    /// pull 1 行の取り込み（LWW 判定込み）。パース不能な行は黙って捨てる。
    static func upsertRemote(_ object: [String: JSONValue], in context: ModelContext) throws

    var recordID: UUID { get }
    var recordUpdatedAt: Date { get }
    var syncState: SyncState { get set }
    var remoteUpdatedAt: Date? { get set }

    /// `POST /v1/sync/push` の payload（snake_case・`apps/api/src/sync/sync-payload.mapper.ts` が正）。
    func syncPayload() -> [String: JSONValue]
}

extension SyncableRecord {
    /// push 受理後の確定。
    public func markSynced() {
        syncState = .synced
        remoteUpdatedAt = recordUpdatedAt
    }

    /// `SYNC_LWW_REJECT`。次の pull でサーバー値に上書きさせる（AC-SY-03）。
    public func markConflicted() {
        syncState = .conflicted
    }
}

public enum SyncMerge {
    /// `LWWResolver`（Domain の純関数）にコレクション固有ロジックを足さない（AC-SY-02）。
    /// 唯一の例外は push で LWW reject された行 — サーバー値を必ず取り込む。
    public static func shouldTakeRemote(
        localSyncState: SyncState,
        localUpdatedAt: Date,
        remoteUpdatedAt: Date,
        remoteDeletedAt: Date?
    ) -> Bool {
        if localSyncState == .conflicted { return true }
        return LWWResolver.resolve(
            localUpdatedAt: localUpdatedAt,
            remoteUpdatedAt: remoteUpdatedAt,
            remoteDeletedAt: remoteDeletedAt
        ) != .keepLocal
    }
}

/// pull 行 (snake_case JSON) の読み取り。型が違えば nil を返し、黙って別値へ落とさない（IOS-2 / BE-2）。
public enum SyncField {
    public static func uuid(_ object: [String: JSONValue], _ key: String) -> UUID? {
        object[key]?.stringValue.flatMap(UUID.init(uuidString:))
    }

    public static func string(_ object: [String: JSONValue], _ key: String) -> String? {
        object[key]?.stringValue
    }

    public static func text(_ object: [String: JSONValue], _ key: String) -> String {
        object[key]?.stringValue ?? ""
    }

    public static func int(_ object: [String: JSONValue], _ key: String) -> Int? {
        object[key]?.intValue
    }

    public static func bool(_ object: [String: JSONValue], _ key: String, default fallback: Bool = false) -> Bool {
        guard let value = object[key], case .bool(let flag) = value else { return fallback }
        return flag
    }

    public static func dateOnly(_ object: [String: JSONValue], _ key: String) -> Date? {
        object[key]?.stringValue.flatMap(APIDateFormat.dateOnly)
    }

    public static func dateTime(_ object: [String: JSONValue], _ key: String) -> Date? {
        object[key]?.stringValue.flatMap(APIDateFormat.dateTime)
    }
}

/// push payload の組み立て。`nil` は必ず `.null` を送る（サーバーは undefined と null を区別する）。
public enum SyncPayloadBuilder {
    public static func optionalString(_ value: String?) -> JSONValue {
        guard let value, !value.isEmpty else { return .null }
        return .string(value)
    }

    public static func optionalInt(_ value: Int?) -> JSONValue {
        guard let value else { return .null }
        return .number(Double(value))
    }

    public static func optionalUUID(_ value: UUID?) -> JSONValue {
        guard let value else { return .null }
        return .string(value.uuidString)
    }

    public static func optionalDateOnly(_ value: Date?) -> JSONValue {
        guard let value else { return .null }
        return .string(APIDateFormat.dateOnlyString(from: value))
    }

    public static func optionalDateTime(_ value: Date?) -> JSONValue {
        guard let value else { return .null }
        return .string(APIDateFormat.dateTimeString(from: value))
    }
}
