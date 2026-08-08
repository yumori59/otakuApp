import Foundation
import Core
import Domain

/// `SharedInboxRepository` の HTTP 実装（`api-contract-delta.md` §4.1 / §4.4 / §4.5）。
/// **受け取り側・Bearer 必須**。
public struct RemoteSharedInboxRepository: SharedInboxRepository {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// `GET /v1/shares/received`。失効・期限切れ・非表示・自分がオーナーのものは含まれない。
    /// 招待 0 件でも空配列（エラーにしない）。
    public func list() async throws -> [SharedInboxItem] {
        let response = try await client.send(.versioned(.get, "/shares/received"), as: SharedInboxListResponse.self)
        return response.items.map { $0.toDomain() }
    }

    /// `POST /v1/shares/received/redeem`。ディープリンクの token を `share_id` に交換する。
    ///
    /// - 招待済み / オーナー本人 → `share_id`
    /// - **招待されていない → `SHARE_NOT_INVITED` 403 → `.shareNotInvited`**
    ///   （汎用マッパー `AppError.from(envelope:)` が既に写す。契約上ここだけが 403 で存在を confirm する）
    /// - 未知 / 失効 / 期限切れ → `SHARE_INVALID` 404 → `.shareInvalid`（3 者を区別しない）
    public func redeem(token: String) async throws -> UUID {
        let body = try JSONEncoder().encode(RedeemShareRequest(token: token))
        let response = try await client.send(
            .versioned(.post, "/shares/received/redeem", body: body),
            as: RedeemShareResponse.self
        )
        return response.shareID
    }

    /// `POST|DELETE /v1/shares/received/:id/hide`。204・冪等。
    /// 非表示はオーナーには見えない（Q3）。招待されていない `:id` は `.shareInvalid`。
    public func setHidden(shareID: UUID, hidden: Bool) async throws {
        let method: Endpoint.Method = hidden ? .post : .delete
        try await client.sendVoid(
            .versioned(method, "/shares/received/\(shareID.uuidString.lowercased())/hide")
        )
    }
}
