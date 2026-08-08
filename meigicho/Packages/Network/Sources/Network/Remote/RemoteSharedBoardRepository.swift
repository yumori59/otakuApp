import Foundation
import Core
import Domain

/// `SharedBoardRepository` の HTTP 実装（`contract-mapping.md` §4.8 / `api-contract-delta.md` §4.2 / §4.3）。
///
/// **`ApiClient`（Bearer 必須）を使う。** 旧 `PublicApiClient` は Q1=A で廃止された
/// （受け取り側は必ずログイン済みアカウントで開く。401 → refresh → 失敗 → ログアウトは
/// 自分のセッションに対する想定どおりの挙動になる — `api-contract-delta.md` §6.1）。
///
/// - `GET /v1/shares/received/:id`
/// - `PATCH /v1/shares/received/:id/items/:item_key`
///
/// addressing は `token` ではなく `share_id`（UUID）。`item_key` / `rev` の HMAC 鍵は
/// サーバー内部の `token_hash` のままなので、iOS 側のロジックは変わらない。
public struct RemoteSharedBoardRepository: SharedBoardRepository {
    private let client: ApiClient
    private let logger = AppLogger(category: "shared-board")

    public init(client: ApiClient) {
        self.client = client
    }

    public func fetchBoard(shareID: UUID) async throws -> SharedBoard {
        let response = try await client.send(
            .versioned(.get, "/shares/received/\(shareID.uuidString.lowercased())"),
            as: SharedBoardResponse.self
        )
        return response.toDomain(logger: logger)
    }

    /// 状況 / 座席の更新。
    ///
    /// - `itemKey` / `rev` は **GET で受け取った不透明値をそのまま返す**（解釈も生成もしない）
    /// - body は `rev` + (`status` か `seat` の少なくとも一方)。**3 キー以外を送らない**
    /// - **自動リトライしない**（429 はそのまま `.rateLimited` で返す）
    public func updateItem(
        shareID: UUID,
        itemKey: String,
        rev: String,
        change: SharedItemChange
    ) async throws -> SharedBoardItem {
        let body = try JSONEncoder().encode(UpdateSharedItemRequest(rev: rev, change: change))
        let response = try await client.send(
            .versioned(
                .patch,
                "/shares/received/\(shareID.uuidString.lowercased())/items/\(Self.escaped(itemKey))",
                body: body
            ),
            as: SharedBoardItemResponse.self,
            promoteError: Self.promoteShareItemConflict
        )
        return response.toDomain(logger: logger)
    }

    // MARK: - CONFLICT の格上げ（**このファイルだけが `details` の形を知る**）

    /// `CONFLICT` 409 + `details.current = { status, seat, rev }` を `.shareItemConflict(current:)` に格上げする。
    ///
    /// 汎用マッパー（`AppError.from(envelope:)`）は**常に `.conflict` のまま**（AC-SB-06-T）。
    /// `CONFLICT` は「既存 id への POST」とも共用されるコードなので、
    /// 文脈を知っているここだけが読み替える。**`details` が読めなければ格上げしない**（AC-SB-05-T）。
    static func promoteShareItemConflict(_ envelope: APIErrorEnvelope) -> AppError? {
        guard envelope.code == "CONFLICT",
              let snapshot = parseCurrent(envelope.details)
        else { return nil }
        return .shareItemConflict(current: snapshot)
    }

    static func parseCurrent(_ details: JSONValue?) -> SharedItemSnapshot? {
        guard let current = details?.objectValue?["current"]?.objectValue,
              let rev = current["rev"]?.stringValue,
              let statusRaw = current["status"]?.stringValue
        else { return nil }

        // `seat` は `null` / 文字列の 2 状態。型が違えば格上げしない（黙って丸めない）
        let seat: String?
        switch current["seat"] {
        case .string(let value): seat = value
        case .null, .none: seat = nil
        default: return nil
        }

        // 未知の status は `.applied` にフォールバックする（P4）。落としたことはログに残す
        let decoded = ApplicationStatus.decoded(statusRaw)
        if decoded.didFallback {
            AppLogger(category: "shared-board")
                .unknownValue(field: "conflict.current.status", rawValue: decoded.rawValue)
        }
        return SharedItemSnapshot(status: decoded.value, seat: seat, rev: rev)
    }

    // MARK: - パス埋め込み

    /// base64url（`-` `_`）はそのまま通し、想定外の文字だけを percent-encode する。
    /// **item_key の中身は解釈しない**。URL を組み立てられずに落ちるのを防ぐだけ。
    private static let pathAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? value
    }
}
