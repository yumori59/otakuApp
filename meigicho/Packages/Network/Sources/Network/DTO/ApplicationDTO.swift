import Foundation
import Core
import Domain

// `contract-mapping.md` §4.6（Applications）。
// **`keyDecodingStrategy` を使わず `CodingKeys` を明示する**（§1.1）。
// リクエストとレスポンスは別型（1 型を双方向に使わない）。

// MARK: - 日付デコードの共通処理

/// DTO の日付文字列 → `Date`。
/// **非 null なのに解釈できない値は黙って握りつぶさず decoding エラーにする**（IOS-2）。
/// `Catalog`（tours / events）の DTO からも使う。
enum ApplicationsAPIDates {
    static func requiredDateTime(_ raw: String, field: String) throws -> Date {
        guard let date = APIDateFormat.dateTime(from: raw) else {
            throw AppError.decoding("invalid datetime for \(field)")
        }
        return date
    }

    static func dateTime(_ raw: String?, field: String) throws -> Date? {
        guard let raw else { return nil }
        return try requiredDateTime(raw, field: field)
    }

    /// date-only（`YYYY-MM-DD`）。JST 00:00 の `Date` にする（E-10）。
    static func dateOnly(_ raw: String?, field: String) throws -> Date? {
        guard let raw else { return nil }
        guard let date = APIDateFormat.dateOnly(from: raw) else {
            throw AppError.decoding("invalid date for \(field)")
        }
        return date
    }
}

// MARK: - Response

struct ApplicationCompanionResponse: Decodable, Sendable {
    let id: UUID
    let identityID: UUID?
    let displayName: String
    let position: Int

    enum CodingKeys: String, CodingKey {
        case id
        case identityID = "identity_id"
        case displayName = "display_name"
        case position
    }
}

/// `api-contract.md` §7 の application 要素。
/// **tour / event の名前を含まない。** 表示名は `tours` / `events` を別途取得して join する（FR-AP-1）。
struct ApplicationResponse: Decodable, Sendable {
    let id: UUID
    let tourID: UUID
    let eventID: UUID
    let repIdentityID: UUID
    let repMembershipID: UUID?
    let roundName: String?
    let appliedOn: String?
    let resultOn: String?
    let status: String
    let seatRaw: String?
    let ticketCount: Int
    let priceYen: Int?
    let note: String?
    let companions: [ApplicationCompanionResponse]
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case tourID = "tour_id"
        case eventID = "event_id"
        case repIdentityID = "rep_identity_id"
        case repMembershipID = "rep_membership_id"
        case roundName = "round_name"
        case appliedOn = "applied_on"
        case resultOn = "result_on"
        case status
        case seatRaw = "seat_raw"
        case ticketCount = "ticket_count"
        case priceYen = "price_yen"
        case note
        case companions
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

/// `GET /v1/applications` の 1 ページ。`next_cursor` は opaque（解釈しない = C7）。
struct ApplicationPageResponse: Decodable, Sendable {
    let items: [ApplicationResponse]
    let nextCursor: String?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

// MARK: - Request

/// `POST /v1/applications` の companions 要素 / `PATCH` の全置換要素。
struct ApplicationCompanionInput: Encodable, Sendable {
    let id: UUID
    let identityID: UUID?
    let displayName: String
    let position: Int

    enum CodingKeys: String, CodingKey {
        case id
        case identityID = "identity_id"
        case displayName = "display_name"
        case position
    }

    init(_ companion: Companion, position: Int) {
        self.id = companion.id
        self.identityID = companion.identityID
        self.displayName = companion.displayName
        self.position = position
    }

    /// 0〜3 件・`position` は 0 起点連番・`identity_id` の重複は**送信前に除去**する
    /// （AC-AP-02-T / AC-AP-03-T。BE も 400 で弾くが、iOS 側で作らせない）。
    static func normalized(_ companions: [Companion]) -> [ApplicationCompanionInput] {
        var seen = Set<UUID>()
        var result: [ApplicationCompanionInput] = []
        for companion in companions.sorted(by: { $0.position < $1.position }) {
            if let identityID = companion.identityID {
                guard seen.insert(identityID).inserted else { continue }
            }
            guard result.count < ApplicationLimits.maxCompanions else { break }
            result.append(ApplicationCompanionInput(companion, position: result.count))
        }
        return result
    }
}

enum ApplicationLimits {
    /// `api-contract.md` §7「companions は 0〜3 件」
    static let maxCompanions = 3
}

/// `POST /v1/applications`（`contract-mapping.md` §4.6）。
///
/// **tour / event はこの複合 POST でしか作れない**（`POST /v1/tours` / `POST /v1/events` は存在しない = C3）。
/// サーバーは `tour` を `(owner, name)` で find-or-create するため、
/// **返ってくる `tour_id` は送った `tour.id` と異なりうる**（レスポンスを正とする）。
struct CreateApplicationRequest: Encodable, Sendable {
    let draft: ApplicationDraft

    enum CodingKeys: String, CodingKey {
        case id
        case tour
        case event
        case repIdentityID = "rep_identity_id"
        case repMembershipID = "rep_membership_id"
        case roundName = "round_name"
        case appliedOn = "applied_on"
        case resultOn = "result_on"
        case status
        case seatRaw = "seat_raw"
        case ticketCount = "ticket_count"
        case priceYen = "price_yen"
        case note
        case companions
    }

    struct TourInput: Encodable, Sendable {
        let id: UUID
        let name: String
        let artistNameRaw: String?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case artistNameRaw = "artist_name_raw"
        }
    }

    struct EventInput: Encodable, Sendable {
        let id: UUID
        let name: String
        let venueNameRaw: String?
        let eventDate: String?
        let startsAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case venueNameRaw = "venue_name_raw"
            case eventDate = "event_date"
            case startsAt = "starts_at"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(draft.id, forKey: .id)
        try container.encode(
            TourInput(
                id: draft.tour.id,
                name: draft.tour.name,
                artistNameRaw: Self.nullIfEmpty(draft.tour.artistNameRaw)
            ),
            forKey: .tour
        )
        try container.encode(
            EventInput(
                id: draft.event.id,
                name: draft.event.name,
                venueNameRaw: Self.nullIfEmpty(draft.event.venueNameRaw),
                eventDate: draft.event.eventDate.map(APIDateFormat.dateOnlyString(from:)),
                startsAt: draft.event.startsAt.map(APIDateFormat.dateTimeString(from:))
            ),
            forKey: .event
        )
        try container.encode(draft.repIdentityID, forKey: .repIdentityID)
        // FR-AP-7 / AC-AP-12: 会員情報連携は今回スコープ外。**常に null を送る**（値を入れる経路を持たない）
        try container.encodeNil(forKey: .repMembershipID)
        try container.encodeIfPresent(Self.nullIfEmpty(draft.roundName), forKey: .roundName)
        try container.encodeIfPresent(
            draft.appliedOn.map(APIDateFormat.dateOnlyString(from:)), forKey: .appliedOn
        )
        try container.encodeIfPresent(
            draft.resultOn.map(APIDateFormat.dateOnlyString(from:)), forKey: .resultOn
        )
        try container.encode(draft.status.rawValue, forKey: .status)
        try container.encodeIfPresent(Self.nullIfEmpty(draft.seatRaw), forKey: .seatRaw)
        try container.encode(draft.ticketCount, forKey: .ticketCount)
        try container.encodeIfPresent(draft.priceYen, forKey: .priceYen)
        try container.encodeIfPresent(Self.nullIfEmpty(draft.note), forKey: .note)
        try container.encode(ApplicationCompanionInput.normalized(draft.companions), forKey: .companions)
    }

    /// 空文字は送らない（BE は `null` 相当として扱う。空文字で上書きしない）。
    private static func nullIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// `PATCH /v1/applications/:id`。
/// `Patchable` で「送らない」と「`null` を送る」を区別する（§1.2）。
/// **`tour_id` / `event_id` は送れない**（BE が 400。型として持たない）。
struct UpdateApplicationRequest: Encodable, Sendable {
    let patch: ApplicationPatch

    enum CodingKeys: String, CodingKey {
        case repIdentityID = "rep_identity_id"
        case repMembershipID = "rep_membership_id"
        case roundName = "round_name"
        case appliedOn = "applied_on"
        case resultOn = "result_on"
        case status
        case seatRaw = "seat_raw"
        case ticketCount = "ticket_count"
        case priceYen = "price_yen"
        case note
        case companions
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodePatch(patch.repIdentityID, forKey: .repIdentityID)
        try container.encodePatch(patch.repMembershipID, forKey: .repMembershipID)
        try container.encodePatch(patch.roundName, forKey: .roundName)
        try container.encodePatch(patch.appliedOn, forKey: .appliedOn) {
            APIDateFormat.dateOnlyString(from: $0)
        }
        try container.encodePatch(patch.resultOn, forKey: .resultOn) {
            APIDateFormat.dateOnlyString(from: $0)
        }
        try container.encodePatch(patch.status, forKey: .status) { $0.rawValue }
        try container.encodePatch(patch.seatRaw, forKey: .seatRaw)
        try container.encodePatch(patch.ticketCount, forKey: .ticketCount)
        try container.encodePatch(patch.priceYen, forKey: .priceYen)
        try container.encodePatch(patch.note, forKey: .note)
        // companions は**全置換**。position を 0 起点で振り直す
        try container.encodePatch(patch.companions, forKey: .companions) {
            ApplicationCompanionInput.normalized($0)
        }
    }
}

// MARK: - Domain へのマッピング

extension ApplicationCompanionResponse {
    func toDomain() -> Companion {
        Companion(
            id: id,
            identityID: identityID,
            displayName: displayName,
            position: position
        )
    }
}

extension ApplicationResponse {
    func toDomain() throws -> ApplicationEntry {
        let decodedStatus = ApplicationStatus.decoded(status)
        if decodedStatus.didFallback {
            // 未知値を黙って落とさない（BE-2 の iOS 版）。値そのものはコードなのでログに出してよい
            AppLogger(category: "applications").unknownValue(field: "status", rawValue: decodedStatus.rawValue)
        }
        return ApplicationEntry(
            id: id,
            tourID: tourID,
            eventID: eventID,
            repIdentityID: repIdentityID,
            repMembershipID: repMembershipID,
            roundName: roundName,
            appliedOn: try ApplicationsAPIDates.dateOnly(appliedOn, field: "application.applied_on"),
            resultOn: try ApplicationsAPIDates.dateOnly(resultOn, field: "application.result_on"),
            status: decodedStatus.value,
            seatRaw: seatRaw ?? "",
            ticketCount: ticketCount,
            priceYen: priceYen,
            companions: companions
                .sorted { $0.position < $1.position }
                .map { $0.toDomain() },
            note: note ?? "",
            updatedAt: try ApplicationsAPIDates.requiredDateTime(updatedAt, field: "application.updated_at")
        )
    }
}

extension ApplicationPageResponse {
    func toDomain() throws -> ApplicationPage {
        ApplicationPage(
            items: try items.map { try $0.toDomain() },
            nextCursor: nextCursor,
            hasMore: hasMore
        )
    }
}
