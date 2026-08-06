import Foundation
import Core
import Domain

/// `ShareRepository` の HTTP 実装（`contract-mapping.md` §4.7）。**オーナー側・Bearer 必須**。
///
/// 受け取り側（`/public/shares/:token`）はこのクライアントを使わない。
/// あちらは `PublicApiClient` + `SharedBoardRepository`（T4b）。
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
            as: CreateShareResponse.self
        )
        return response.toDomain()
    }

    /// 失効（204・冪等）。**`permission` を変更する API は無いので、変更はこれ + 再発行**。
    public func revoke(id: UUID) async throws {
        try await client.sendVoid(.versioned(.delete, "/shares/\(id.uuidString.lowercased())"))
    }
}
