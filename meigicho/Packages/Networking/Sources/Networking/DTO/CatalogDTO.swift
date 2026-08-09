import Foundation
import Core
import Domain

// `contract-mapping.md` §4.5（Tours / Events）。
// **`POST /v1/tours` / `POST /v1/events` は存在しない**ため、作成用の Request 型を定義しない（C3）。
// tour / event は `POST /v1/applications` の find-or-create でしか作れない。

// MARK: - Response

struct TourResponse: Decodable, Sendable {
    let id: UUID
    let name: String
    let artistNameRaw: String?
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artistNameRaw = "artist_name_raw"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct TourListResponse: Decodable, Sendable {
    let items: [TourResponse]
}

struct EventResponse: Decodable, Sendable {
    let id: UUID
    let tourID: UUID
    let name: String
    let venueNameRaw: String?
    /// date-only。**null がありうる**（E-8）
    let eventDate: String?
    /// datetime。`event_date` とは別物（混同しない）
    let startsAt: String?
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case tourID = "tour_id"
        case name
        case venueNameRaw = "venue_name_raw"
        case eventDate = "event_date"
        case startsAt = "starts_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct EventListResponse: Decodable, Sendable {
    let items: [EventResponse]
}

// MARK: - Request

/// `PATCH /v1/tours/:id`。変更できるのは `name` / `artist_name_raw` のみ。
struct UpdateTourRequest: Encodable, Sendable {
    let patch: TourPatch

    enum CodingKeys: String, CodingKey {
        case name
        case artistNameRaw = "artist_name_raw"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodePatch(patch.name, forKey: .name)
        try container.encodePatch(patch.artistNameRaw, forKey: .artistNameRaw)
    }
}

/// `PATCH /v1/events/:id`。**`tour_id` の付け替えは不可**（型として持たない）。
struct UpdateEventRequest: Encodable, Sendable {
    let patch: EventPatch

    enum CodingKeys: String, CodingKey {
        case name
        case venueNameRaw = "venue_name_raw"
        case eventDate = "event_date"
        case startsAt = "starts_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodePatch(patch.name, forKey: .name)
        try container.encodePatch(patch.venueNameRaw, forKey: .venueNameRaw)
        try container.encodePatch(patch.eventDate, forKey: .eventDate) {
            APIDateFormat.dateOnlyString(from: $0)
        }
        try container.encodePatch(patch.startsAt, forKey: .startsAt) {
            APIDateFormat.dateTimeString(from: $0)
        }
    }
}

// MARK: - Domain へのマッピング

extension TourResponse {
    func toDomain() throws -> Tour {
        Tour(
            id: id,
            name: name,
            // Domain は非 Optional。null は空文字で受ける（送信時は空文字を null に戻す）
            artistNameRaw: artistNameRaw ?? "",
            updatedAt: try ApplicationsAPIDates.requiredDateTime(updatedAt, field: "tour.updated_at")
        )
    }
}

extension EventResponse {
    func toDomain() throws -> EventEntity {
        EventEntity(
            id: id,
            tourID: tourID,
            name: name,
            venueNameRaw: venueNameRaw ?? "",
            eventDate: try ApplicationsAPIDates.dateOnly(eventDate, field: "event.event_date"),
            startsAt: try ApplicationsAPIDates.dateTime(startsAt, field: "event.starts_at"),
            updatedAt: try ApplicationsAPIDates.requiredDateTime(updatedAt, field: "event.updated_at")
        )
    }
}
