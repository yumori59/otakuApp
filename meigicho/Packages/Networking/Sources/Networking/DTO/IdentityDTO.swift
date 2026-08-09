import Foundation
import Core
import Domain

// `contract-mapping.md` §4.3。
// **`keyDecodingStrategy` を使わず CodingKeys を明示する**（§1.1）。
// リクエストとレスポンスは別型（1 型を双方向に使わない）。

// MARK: - Response

struct IdentityListResponse: Decodable, Sendable {
    let items: [IdentityResponse]
}

/// `GET/POST/PATCH /v1/identities`。**11 フィールド全てを保持する**（AC-ID-01-T）。
struct IdentityResponse: Decodable, Sendable {
    let id: UUID
    let displayName: String
    let relation: String
    let color: String
    let joinedOn: String?
    let note: String?
    let historyVisible: Bool
    let sortOrder: Int
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case relation
        case color
        case joinedOn = "joined_on"
        case note
        case historyVisible = "history_visible"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

// MARK: - Request

/// `POST /v1/identities`。**`id` はクライアント発行 UUID v7**（§2.2）。
/// 既知の値は常に送る（`history_visible` の既定を明示するため。Q9）。
struct CreateIdentityRequest: Encodable, Sendable {
    let id: UUID
    let displayName: String
    let relation: String
    let color: String
    let joinedOn: String?
    let note: String?
    let historyVisible: Bool
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case relation
        case color
        case joinedOn = "joined_on"
        case note
        case historyVisible = "history_visible"
        case sortOrder = "sort_order"
    }
}

/// `PATCH /v1/identities/:id`。`Patchable` で「送らない」と「`null`」を区別する（§1.2）。
struct UpdateIdentityRequest: Encodable, Sendable {
    var displayName: Patchable<String> = .unchanged
    var relation: Patchable<Relation> = .unchanged
    var color: Patchable<String> = .unchanged
    var joinedOn: Patchable<Date> = .unchanged
    var note: Patchable<String> = .unchanged
    var historyVisible: Patchable<Bool> = .unchanged
    var sortOrder: Patchable<Int> = .unchanged

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case relation
        case color
        case joinedOn = "joined_on"
        case note
        case historyVisible = "history_visible"
        case sortOrder = "sort_order"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodePatch(displayName, forKey: .displayName)
        try container.encodePatch(relation, forKey: .relation)
        try container.encodePatch(color, forKey: .color)
        try container.encodePatch(joinedOn, forKey: .joinedOn) { APIDateFormat.dateOnlyString(from: $0) }
        try container.encodePatch(note, forKey: .note)
        try container.encodePatch(historyVisible, forKey: .historyVisible)
        try container.encodePatch(sortOrder, forKey: .sortOrder)
    }
}

// MARK: - Domain へのマッピング

extension IdentityResponse {
    func toDomain() -> Identity {
        Identity(
            id: id,
            displayName: displayName,
            relation: Self.decodedRelation(relation),
            colorHex: color,
            joinedOn: joinedOn.flatMap { APIDateFormat.dateOnly(from: $0) },
            historyVisible: historyVisible,
            note: note ?? "",
            sortOrder: sortOrder,
            updatedAt: APIDateFormat.dateTime(from: updatedAt) ?? Date()
        )
    }

    /// 未知の `relation` で失敗させない。フォールバックした事実はログに残す（BE-2 の iOS 版）。
    private static func decodedRelation(_ raw: String) -> Relation {
        let decoded = Relation.decoded(raw)
        if decoded.didFallback {
            AppLogger(category: "identities").unknownValue(field: "relation", rawValue: raw)
        }
        return decoded.value
    }
}

extension Identity {
    /// `POST /v1/identities` の本文。
    func toCreateRequest() -> CreateIdentityRequest {
        CreateIdentityRequest(
            id: id,
            displayName: displayName,
            relation: relation.rawValue,
            color: colorHex,
            joinedOn: joinedOn.map { APIDateFormat.dateOnlyString(from: $0) },
            // 受信時は `?? ""` で埋めるので、送信時は空文字を `null` に戻す（§3.1）
            note: note.isEmpty ? nil : note,
            historyVisible: historyVisible,
            sortOrder: sortOrder
        )
    }
}

extension IdentityPatch {
    /// `PATCH /v1/identities/:id` の本文。
    func toRequest() -> UpdateIdentityRequest {
        var request = UpdateIdentityRequest()
        request.displayName = displayName
        request.relation = relation
        request.color = colorHex
        request.joinedOn = joinedOn
        switch note {
        case .unchanged:
            request.note = .unchanged
        case .set(let value):
            request.note = .set((value?.isEmpty ?? true) ? nil : value)
        }
        request.historyVisible = historyVisible
        request.sortOrder = sortOrder
        return request
    }
}
