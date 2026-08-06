import Foundation
import Core
import Domain

// `contract-mapping.md` §4.7 / `api-contract-delta.md` §3。
// **`keyDecodingStrategy` を使わず CodingKeys を明示する**（§1.1）。
//
// C4: `token` / `url` は **`POST /v1/shares` の 201 にしか存在しない**。
// `GET /v1/shares` の items には含まれない（BE が意図的に返さない）。
// そのため `ShareResponse` には `token` / `url` を**フィールドとして定義しない**（AC-SH-03-T）。

// MARK: - Response

struct ShareListResponse: Decodable, Sendable {
    let items: [ShareResponse]
}

/// `GET /v1/shares` の items 要素。
///
/// `permission` / `scope_type` は enum で受ける。**未知値は黙って `read` / `tour` に落とさず
/// デコードエラーにする**（BE-2 の iOS 版。`AppEnums.swift` の `SharePermission` コメント）。
struct ShareResponse: Decodable, Sendable {
    let id: UUID
    let scopeType: ShareScope
    let scopeID: UUID?
    let scopeName: String?
    let permission: SharePermission
    let maskMemberNo: Bool
    let sharedWithAccountIDs: [String]
    let expiresAt: String?
    let revokedAt: String?
    let viewCount: Int
    let lastViewedAt: String?
    /// `api-contract-delta.md` §3 で追加（既定 0）
    let editCount: Int
    let lastEditedAt: String?
    let createdAt: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case scopeType = "scope_type"
        case scopeID = "scope_id"
        case scopeName = "scope_name"
        case permission
        case maskMemberNo = "mask_member_no"
        case sharedWithAccountIDs = "shared_with_account_ids"
        case expiresAt = "expires_at"
        case revokedAt = "revoked_at"
        case viewCount = "view_count"
        case lastViewedAt = "last_viewed_at"
        case editCount = "edit_count"
        case lastEditedAt = "last_edited_at"
        case createdAt = "created_at"
        case isActive = "is_active"
    }
}

/// `POST /v1/shares` の 201。**ここだけが `token` / `url` を持つ**。
/// 一覧のキー（`scope_name` / `view_count` / `edit_count` / `is_active` など）は返らない。
struct CreateShareResponse: Decodable, Sendable {
    let id: UUID
    let token: String
    let url: String
    let scopeType: ShareScope
    let scopeID: UUID?
    let permission: SharePermission
    let maskMemberNo: Bool
    let sharedWithAccountIDs: [String]
    let expiresAt: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case token
        case url
        case scopeType = "scope_type"
        case scopeID = "scope_id"
        case permission
        case maskMemberNo = "mask_member_no"
        case sharedWithAccountIDs = "shared_with_account_ids"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

// MARK: - Request

/// `POST /v1/shares`。
///
/// - `id` は**送らない**（サーバー生成）
/// - `scope_type == "identity_summary"` のときは **`scope_id` / `permission` のキー自体を作らない**
///   （`scope_id` を送ると 400 / `permission: "write"` との組み合わせも 400 = §4.7）
/// - `expires_at` は送らない。**サーバー既定の +30 日**に任せる（`create-share.dto.ts` の
///   `DEFAULT_EXPIRES_IN_DAYS`）。UI に期限の入力欄が無いのに勝手な値を送らない
struct CreateShareRequest: Encodable, Sendable {
    let selection: ShareScopeSelection
    let maskMemberNo: Bool
    let sharedWithAccountIDs: [String]

    enum CodingKeys: String, CodingKey {
        case scopeType = "scope_type"
        case scopeID = "scope_id"
        case permission
        case maskMemberNo = "mask_member_no"
        case sharedWithAccountIDs = "shared_with_account_ids"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selection.scopeType.rawValue, forKey: .scopeType)
        // AC-SH-01-T: identitySummary からは scope_id / permission のキーが生成されない
        if let scopeID = selection.scopeID {
            try container.encode(scopeID.uuidString.lowercased(), forKey: .scopeID)
        }
        if let permission = selection.permission {
            try container.encode(permission.rawValue, forKey: .permission)
        }
        try container.encode(maskMemberNo, forKey: .maskMemberNo)
        try container.encode(sharedWithAccountIDs, forKey: .sharedWithAccountIDs)
    }
}

// MARK: - Domain へのマッピング

extension ShareResponse {
    func toDomain() -> ShareLink {
        ShareLink(
            id: id,
            scopeType: scopeType,
            scopeID: scopeID,
            scopeName: scopeName,
            permission: permission,
            maskMemberNo: maskMemberNo,
            sharedWithAccountIDs: sharedWithAccountIDs,
            expiresAt: expiresAt.flatMap { APIDateFormat.dateTime(from: $0) },
            revokedAt: revokedAt.flatMap { APIDateFormat.dateTime(from: $0) },
            viewCount: viewCount,
            lastViewedAt: lastViewedAt.flatMap { APIDateFormat.dateTime(from: $0) },
            editCount: editCount,
            lastEditedAt: lastEditedAt.flatMap { APIDateFormat.dateTime(from: $0) },
            createdAt: APIDateFormat.dateTime(from: createdAt) ?? Date(),
            isActive: isActive
        )
    }
}

extension CreateShareResponse {
    /// 発行直後の 1 件。
    ///
    /// 201 は `scope_name` / `view_count` / `edit_count` / `is_active` を返さないので、
    /// **発行直後として自明な値**（0 件・失効なし・有効）で埋める。
    /// 実際の値は次の `GET /v1/shares` で上書きされる。
    func toDomain() -> IssuedShareLink {
        let link = ShareLink(
            id: id,
            scopeType: scopeType,
            scopeID: scopeID,
            scopeName: nil,
            permission: permission,
            maskMemberNo: maskMemberNo,
            sharedWithAccountIDs: sharedWithAccountIDs,
            expiresAt: expiresAt.flatMap { APIDateFormat.dateTime(from: $0) },
            revokedAt: nil,
            viewCount: 0,
            lastViewedAt: nil,
            editCount: 0,
            lastEditedAt: nil,
            createdAt: APIDateFormat.dateTime(from: createdAt) ?? Date(),
            isActive: true
        )
        return IssuedShareLink(link: link, token: token, url: url)
    }
}
