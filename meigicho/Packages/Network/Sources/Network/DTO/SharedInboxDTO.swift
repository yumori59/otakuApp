import Foundation
import Core
import Domain

// 受信箱（`GET /v1/shares/received`）・redeem（`POST /v1/shares/received/redeem`）・
// hide（`POST|DELETE /v1/shares/received/:id/hide`）の DTO。`api-contract-delta.md` §4.1 / §4.4 / §4.5。
// **`keyDecodingStrategy` を使わず CodingKeys を明示する**（§1.1）。

// MARK: - Response

struct SharedInboxListResponse: Decodable, Sendable {
    let items: [SharedInboxItemResponse]
}

/// `GET /v1/shares/received` の items 要素。
///
/// **含まれないもの**（NFR-1 / AC-SI-45）: `token` / `token_hash` / `scope_id` /
/// オーナーの内部 UUID / 他の招待者の ACC-ID / 会員番号 / 申込の中身。
/// ここに無いフィールドを「あとで足す」前に契約を確認すること。
struct SharedInboxItemResponse: Decodable, Sendable {
    let shareID: UUID
    let scopeType: ShareScope
    /// **null を許す**（サーバーが tour 名を解決できない場合）。1 件の欠損で一覧全体を落とさない
    let scopeName: String?
    let permission: SharePermission
    let owner: SharedInboxOwnerResponse
    let invitedAt: String
    let expiresAt: String?
    let unread: Bool

    enum CodingKeys: String, CodingKey {
        case shareID = "share_id"
        case scopeType = "scope_type"
        case scopeName = "scope_name"
        case permission
        case owner
        case invitedAt = "invited_at"
        case expiresAt = "expires_at"
        case unread
    }

    func toDomain() -> SharedInboxItem {
        SharedInboxItem(
            shareID: shareID,
            scopeType: scopeType,
            scopeName: scopeName,
            permission: permission,
            owner: owner.toDomain(),
            invitedAt: APIDateFormat.dateTime(from: invitedAt) ?? Date(),
            expiresAt: expiresAt.flatMap { APIDateFormat.dateTime(from: $0) },
            unread: unread
        )
    }
}

struct SharedInboxOwnerResponse: Decodable, Sendable {
    /// **null を許す**（プロフィール未解決。`received-share.presenter.ts` の型は `string | null`）
    let accountID: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case displayName = "display_name"
    }

    func toDomain() -> SharedInboxOwner {
        SharedInboxOwner(accountID: accountID, displayName: displayName)
    }
}

/// `POST /v1/shares/received/redeem` の 200。
struct RedeemShareResponse: Decodable, Sendable {
    let shareID: UUID

    enum CodingKeys: String, CodingKey {
        case shareID = "share_id"
    }
}

// MARK: - Request

/// `POST /v1/shares/received/redeem`。
struct RedeemShareRequest: Encodable, Sendable {
    let token: String
}
