import Foundation
import Core
import Domain

/// `ShareRepository` の HTTP 実装（`contract-mapping.md` §4.7 / `api-contract-delta.md` §1〜§3）。
/// **オーナー側・Bearer 必須**。
///
/// 受け取り側（`GET|PATCH /v1/shares/received/:id`）はこのクライアントを使わない。
/// あちらは `RemoteSharedInboxRepository` / `RemoteSharedBoardRepository`（同じ `ApiClient` だが別 Repository）。
public struct RemoteShareRepository: ShareRepository {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// 失効済みも含む全件（BE は `created_at desc`）。
    public func list() async throws -> [ShareLink] {
        let response = try await client.send(.versioned(.get, "/shares"), as: ShareListResponse.self)
        return response.items.map { $0.toDomain() }
    }

    /// 発行。**`token` / `url` を受け取れるのはこの戻り値だけ**（C4）。
    ///
    /// `permission: .write` の公演数上限（free = 3）は**サーバーだけが判定する**。
    /// ここで件数を数えて事前に弾かない（IOS-4）。超過時は `PLAN_LIMIT_SHARE_WRITE` 403 が
    /// `AppError.planLimitShareWrite(limit:current:)` に写る。
    ///
    /// 存在しない ACC-ID が混ざると `SHARE_RECIPIENT_UNKNOWN` 400 が返る。
    /// **`details.unknown_account_ids` を読むのはこのファイルだけ**（§6.3）。
    public func create(
        _ selection: ShareScopeSelection,
        maskMemberNo: Bool,
        sharedWithAccountIDs: [String]
    ) async throws -> IssuedShareLink {
        let body = try JSONEncoder().encode(
            CreateShareRequest(
                selection: selection,
                maskMemberNo: maskMemberNo,
                sharedWithAccountIDs: sharedWithAccountIDs
            )
        )
        let response = try await client.send(
            .versioned(.post, "/shares", body: body),
            as: CreateShareResponse.self,
            promoteError: Self.promoteRecipientUnknown
        )
        return response.toDomain()
    }

    /// `POST /v1/shares/:id/recipients`。**戻り値は追加後の全件**（差分ではない）。
    /// 既に招待済みの ACC-ID は冪等。バリデーションは `create` と同一（形式 / self / unknown / 20 件上限）。
    public func addRecipients(shareID: UUID, accountIDs: [String]) async throws -> [ShareRecipient] {
        let body = try JSONEncoder().encode(AddRecipientsRequest(accountIDs: accountIDs))
        let response = try await client.send(
            .versioned(.post, "/shares/\(shareID.uuidString.lowercased())/recipients", body: body),
            as: RecipientsResponse.self,
            promoteError: Self.promoteRecipientUnknown
        )
        return response.recipients.map { $0.toDomain() }
    }

    /// `DELETE /v1/shares/:id/recipients/:account_id`。204・冪等。存在しない ACC-ID でも 204。
    public func removeRecipient(shareID: UUID, accountID: String) async throws {
        try await client.sendVoid(
            .versioned(.delete, "/shares/\(shareID.uuidString.lowercased())/recipients/\(Self.escaped(accountID))")
        )
    }

    /// 失効（204・冪等）。**`permission` を変更する API は無いので、変更はこれ + 再発行**。
    public func revoke(id: UUID) async throws {
        try await client.sendVoid(.versioned(.delete, "/shares/\(id.uuidString.lowercased())"))
    }

    // MARK: - `SHARE_RECIPIENT_UNKNOWN` の格上げ（**このファイルだけが `details` の形を知る**）

    /// `SHARE_RECIPIENT_UNKNOWN` 400 + `details.unknown_account_ids` を
    /// `.shareRecipientUnknown(accountIDs:)` に格上げする。
    ///
    /// 汎用マッパー（`AppError.from(envelope:)`）は**常に空配列**（`RemoteSharedBoardRepository` の
    /// `promoteShareItemConflict` と同じ方針）。`details` が読めなければ格上げしない。
    static func promoteRecipientUnknown(_ envelope: APIErrorEnvelope) -> AppError? {
        guard envelope.code == "SHARE_RECIPIENT_UNKNOWN",
              case .array(let rawIDs)? = envelope.details?.objectValue?["unknown_account_ids"]
        else { return nil }
        let ids = rawIDs.compactMap(\.stringValue)
        // 要素の型が違うものが 1 つでも混ざっていたら黙って一部だけ拾わず、格上げしない
        guard ids.count == rawIDs.count else { return nil }
        return .shareRecipientUnknown(accountIDs: ids)
    }

    // MARK: - パス埋め込み

    /// ACC-ID は `^ACC-[0-9A-F]{6}$` の範囲でしか作れないが、パス埋め込みは念のため escape する。
    private static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
