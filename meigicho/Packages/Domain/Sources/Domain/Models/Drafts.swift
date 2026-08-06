import Foundation
import Core

/// `POST /v1/applications` の入力（`contract-mapping.md` §4.6）。
/// tour / event は **この複合 POST でしか作れない**（`POST /v1/tours` は存在しない = C3）。
public struct ApplicationDraft: Equatable, Sendable {
    public var id: UUID
    public var tour: TourDraft
    public var event: EventDraft
    public var repIdentityID: UUID
    /// FR-AP-7: 当面は常に nil
    public var repMembershipID: UUID?
    public var roundName: String?
    public var appliedOn: Date?
    public var resultOn: Date?
    public var status: ApplicationStatus
    public var seatRaw: String
    public var ticketCount: Int
    public var priceYen: Int?
    public var note: String
    /// 0〜3 件。`position` は 0 起点連番、`identity_id` の重複は送信前に除去する
    public var companions: [Companion]

    public init(
        id: UUID = UUIDv7.generate(),
        tour: TourDraft,
        event: EventDraft,
        repIdentityID: UUID,
        repMembershipID: UUID? = nil,
        roundName: String? = nil,
        appliedOn: Date? = nil,
        resultOn: Date? = nil,
        status: ApplicationStatus = .applied,
        seatRaw: String = "",
        ticketCount: Int = 1,
        priceYen: Int? = nil,
        note: String = "",
        companions: [Companion] = []
    ) {
        self.id = id
        self.tour = tour
        self.event = event
        self.repIdentityID = repIdentityID
        self.repMembershipID = repMembershipID
        self.roundName = roundName
        self.appliedOn = appliedOn
        self.resultOn = resultOn
        self.status = status
        self.seatRaw = seatRaw
        self.ticketCount = ticketCount
        self.priceYen = priceYen
        self.note = note
        self.companions = companions
    }
}

public struct TourDraft: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var artistNameRaw: String

    public init(id: UUID = UUIDv7.generate(), name: String, artistNameRaw: String = "") {
        self.id = id
        self.name = name
        self.artistNameRaw = artistNameRaw
    }
}

public struct EventDraft: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var venueNameRaw: String
    public var eventDate: Date?
    public var startsAt: Date?

    public init(
        id: UUID = UUIDv7.generate(),
        name: String,
        venueNameRaw: String = "",
        eventDate: Date? = nil,
        startsAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.venueNameRaw = venueNameRaw
        self.eventDate = eventDate
        self.startsAt = startsAt
    }
}

/// `GET /v1/applications` の 1 ページ。`cursor` は不透明値なので解釈しない（C7）。
public struct ApplicationPage: Equatable, Sendable {
    public let items: [ApplicationEntry]
    public let nextCursor: String?
    public let hasMore: Bool

    public init(items: [ApplicationEntry], nextCursor: String?, hasMore: Bool) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}
