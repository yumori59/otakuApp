import Foundation
import Core
import Domain

/// `SharedBoardRepository` の HTTP 実装（`contract-mapping.md` §4.8 / §5.1）。
///
/// **`ApiClient` / `TokenStore` を参照しない。** 使うのは `PublicApiClient` だけ。
/// 理由: `ApiClient` は 401 で refresh を試み、失敗するとサイレントログアウトする。
/// 共有ボードを開いただけのユーザーが**自分のアカウントからログアウトさせられる**事故になる（R7 / AC-SB-13-M）。
///
/// - `GET /public/shares/:token`
/// - `PATCH /public/shares/:token/items/:item_key`
///
/// **`/v1` プレフィックスを付けない**（`GLOBAL_PREFIX_EXCLUDE`）。`Endpoint.publicPath` が型で保証する。
public struct RemoteSharedBoardRepository: SharedBoardRepository {
    private let client: PublicApiClient
    private let logger = AppLogger(category: "shared-board")

    public init(client: PublicApiClient) {
        self.client = client
    }

    public func fetchBoard(token: String) async throws -> SharedBoard {
        let response = try await client.send(
            .publicPath(.get, "/public/shares/\(Self.escaped(token))"),
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
        token: String,
        itemKey: String,
        rev: String,
        change: SharedItemChange
    ) async throws -> SharedBoardItem {
        let body = try JSONEncoder().encode(UpdateSharedItemRequest(rev: rev, change: change))
        let response = try await client.send(
            .publicPath(
                .patch,
                "/public/shares/\(Self.escaped(token))/items/\(Self.escaped(itemKey))",
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
    /// **token / item_key の中身は解釈しない**。URL を組み立てられずに落ちるのを防ぐだけ。
    private static let pathAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? value
    }
}
