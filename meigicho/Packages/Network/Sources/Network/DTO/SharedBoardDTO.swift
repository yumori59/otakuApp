import Foundation
import Core
import Domain

// `contract-mapping.md` §4.8 / `api-contract-delta.md` §4。
// **Bearer を使わない経路**（`/public/shares/:token`）。`/v1` プレフィックスは付かない。
// **`keyDecodingStrategy` を使わず CodingKeys を明示する**（§1.1）。

// MARK: - Response

/// `GET /public/shares/:token`。
///
/// **`scope_type` によって items の形が完全に別物**（`api-contract.md` §8 /
/// `public-share.presenter.ts` の `TourSharePayload` / `IdentitySummaryPayload`）。
/// トップレベルの `scope_type` を先に読み、items のデコード経路を分ける（P7）。
struct SharedBoardResponse: Decodable, Sendable {
    /// `read` / `write`。**`identity_summary` は常に `read`**
    let permission: SharePermission
    let generatedAt: String
    let content: Content

    /// items の形は 2 通りしかない。**未知の `scope_type` はデコードで失敗させる**（黙って落とさない）。
    enum Content: Sendable {
        case tour(tour: SharedBoardTourResponse?, items: [SharedBoardItemResponse])
        case identitySummary(items: [SharedIdentitySummaryItemResponse])
    }

    enum CodingKeys: String, CodingKey {
        case scopeType = "scope_type"
        case permission
        case tour
        case generatedAt = "generated_at"
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scopeType = try container.decode(ShareScope.self, forKey: .scopeType)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)

        switch scopeType {
        case .tour:
            // tour は read / write の両方がありうる。**欠けていたら失敗させる**（write に倒さない・read にも倒さない）
            permission = try container.decode(SharePermission.self, forKey: .permission)
            content = .tour(
                tour: try container.decodeIfPresent(SharedBoardTourResponse.self, forKey: .tour),
                items: try container.decode([SharedBoardItemResponse].self, forKey: .items)
            )
        case .identitySummary:
            // 書き込み経路が存在しないスコープ。キーが無ければ**最も制限の強い read** とみなす
            permission = try container.decodeIfPresent(SharePermission.self, forKey: .permission) ?? .read
            content = .identitySummary(
                items: try container.decode([SharedIdentitySummaryItemResponse].self, forKey: .items)
            )
        }
    }
}

/// identity_summary の items 要素。
///
/// **`visible: false` の行は `application_count` / `won_count` のキー自体が来ない**
/// （`toIdentitySummaryItem` — D10 / AC-SH-18）。Optional で受け、`nil` を「非公開」として扱う。
struct SharedIdentitySummaryItemResponse: Decodable, Sendable {
    let name: String
    let visible: Bool
    let applicationCount: Int?
    let wonCount: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case visible
        case applicationCount = "application_count"
        case wonCount = "won_count"
    }
}

struct SharedBoardTourResponse: Decodable, Sendable {
    let name: String?
    let artistName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case artistName = "artist_name"
    }
}

/// `GET` の items 要素 / `PATCH` の 200（同形）。
///
/// **P1: `item_key` / `rev` / `editable` は `permission == "write"` のときだけ現れる。**
/// キーごと存在しないので Optional で受け、`nil` を「編集不可」として扱う。
/// **`editable ?? true` にしない。**
struct SharedBoardItemResponse: Decodable, Sendable {
    let eventName: String
    let venue: String?
    let eventDate: String?
    let roundName: String?
    let repName: String
    let repColor: String?
    let companions: [String]
    /// 未知値は `.applied` にフォールバックしログに残す（P4）ので、生の String で受ける
    let status: String
    /// `null` / 空文字 / 文字列の 3 状態（P5）
    let seat: String?
    let itemKey: String?
    let rev: String?
    let editable: Bool?

    enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case venue
        case eventDate = "event_date"
        case roundName = "round_name"
        case repName = "rep_name"
        case repColor = "rep_color"
        case companions
        case status
        case seat
        case itemKey = "item_key"
        case rev
        case editable
    }
}

// MARK: - Request

/// `PATCH /public/shares/:token/items/:item_key`。
///
/// - `rev` 必須 + `status` / `seat` の**少なくとも一方**（両方無いと 400）
/// - **3 キー以外を送ったら 400**（`forbidNonWhitelisted`）。`round_name` / `note` / `companions` を送らない
/// - `seat` は「送らない」「`null` を送る」「空文字を送る」の 3 状態を区別する（P5）
///
/// `SharedItemChange` からしか作れないので、**空ボディを型で作れない**。
struct UpdateSharedItemRequest: Encodable, Sendable {
    let rev: String
    let change: SharedItemChange

    enum CodingKeys: String, CodingKey {
        case rev
        case status
        case seat
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rev, forKey: .rev)
        if let status = change.status {
            try container.encode(status.rawValue, forKey: .status)
        }
        // `String??`: 外側 nil = キーを作らない / `.some(nil)` = 明示的な null / `.some(値)` = 文字列
        if case .some(let seat) = change.seat {
            if let seat {
                try container.encode(seat, forKey: .seat)
            } else {
                try container.encodeNil(forKey: .seat)
            }
        }
    }
}

// MARK: - Domain へのマッピング

extension SharedBoardResponse {
    func toDomain(logger: AppLogger) -> SharedBoard {
        let generated = APIDateFormat.dateTime(from: generatedAt) ?? Date()
        switch content {
        case .tour(let tour, let items):
            return SharedBoard(
                permission: permission,
                tourName: tour?.name,
                artistName: tour?.artistName,
                generatedAt: generated,
                // 並び順を行 id の一部に使う（read リンクには item_key が無い）
                items: items.enumerated().map { $0.element.toDomain(rowIndex: $0.offset, logger: logger) }
            )
        case .identitySummary(let items):
            return SharedBoard(
                permission: permission,
                generatedAt: generated,
                identities: items.enumerated().map { $0.element.toDomain(rowIndex: $0.offset, logger: logger) }
            )
        }
    }
}

extension SharedIdentitySummaryItemResponse {
    func toDomain(rowIndex: Int, logger: AppLogger) -> SharedIdentitySummaryItem {
        let counts = SharedIdentityCounts(applicationCount: applicationCount, wonCount: wonCount)

        // 契約違反（`visible: true` なのに件数キーが無い / `visible: false` なのに件数が来た）は
        // **マスキング側に倒す**。件数を 0 と偽らず、非公開の行に件数を出しもしない
        if visible != (counts != nil) {
            logger.unknownValue(
                field: "identity_summary.visible",
                rawValue: visible ? "visible_without_counts" : "hidden_with_counts"
            )
        }
        return SharedIdentitySummaryItem(
            rowIndex: rowIndex,
            name: name,
            counts: visible ? counts : nil
        )
    }
}

extension SharedBoardItemResponse {
    /// `rowIndex` は GET の items 内の並び順。`PATCH` の 200（1 件）では使わない。
    func toDomain(rowIndex: Int = 0, logger: AppLogger) -> SharedBoardItem {
        let decoded = ApplicationStatus.decoded(status)
        if decoded.didFallback {
            // 未知値を黙って落とさない（BE-2 の iOS 版 / E-12）
            logger.unknownValue(field: "shared_item.status", rawValue: decoded.rawValue)
        }
        return SharedBoardItem(
            rowIndex: rowIndex,
            eventName: eventName,
            venue: venue,
            eventDate: eventDate.flatMap { APIDateFormat.dateOnly(from: $0) },
            roundName: roundName,
            repName: repName,
            repColor: repColor,
            companions: companions,
            status: decoded.value,
            seat: seat,
            // 3 つ揃ったときだけ handle になる（P2）。read リンクでは nil
            handle: SharedItemHandle(itemKey: itemKey, rev: rev, editable: editable)
        )
    }
}
