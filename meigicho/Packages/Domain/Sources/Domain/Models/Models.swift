import Foundation
import Core

/// 名義（`contract-mapping.md` §3.1）。
/// `memberships` は持たない（BE は別エンドポイント。`IdentityStore` が `identityID` で引く）。
public struct Identity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public var relation: Relation
    /// API の `color`
    public var colorHex: String
    public var joinedOn: Date?
    /// 既定は **false**（共有はオプトイン / Q9・`docs/03` §4.4）
    public var historyVisible: Bool
    /// API は `note: String?`。受信時に `?? ""`、送信時に空文字を `nil` にする
    public var note: String
    public var sortOrder: Int
    public var updatedAt: Date

    public init(
        id: UUID = UUIDv7.generate(),
        displayName: String,
        relation: Relation,
        colorHex: String,
        joinedOn: Date? = nil,
        historyVisible: Bool = false,
        note: String = "",
        sortOrder: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.relation = relation
        self.colorHex = colorHex
        self.joinedOn = joinedOn
        self.historyVisible = historyVisible
        self.note = note
        self.sortOrder = sortOrder
        self.updatedAt = updatedAt
    }
}

/// ファンクラブ会員情報（`contract-mapping.md` §3.2）。
/// 会員番号は全桁を平文で保存・表示する（2026-08-20 ユーザー判断により暗号化・下4桁表示を撤回。共有時のマスキングは維持）。
public struct Membership: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var identityID: UUID
    public var fanClubNameRaw: String
    public var memberNo: String?
    public var rank: String?
    public var renewalOn: Date?
    public var feeYen: Int?
    public var autoRenew: Bool
    public var note: String

    public init(
        id: UUID = UUIDv7.generate(),
        identityID: UUID,
        fanClubNameRaw: String,
        memberNo: String? = nil,
        rank: String? = nil,
        renewalOn: Date? = nil,
        feeYen: Int? = nil,
        autoRenew: Bool = false,
        note: String = ""
    ) {
        self.id = id
        self.identityID = identityID
        self.fanClubNameRaw = fanClubNameRaw
        self.memberNo = memberNo
        self.rank = rank
        self.renewalOn = renewalOn
        self.feeYen = feeYen
        self.autoRenew = autoRenew
        self.note = note
    }
}

/// 同行者（`contract-mapping.md` §3.3）。PATCH は全置換なので `id` と `position` が必須。
public struct Companion: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var identityID: UUID?
    public var displayName: String
    public var position: Int

    public init(id: UUID = UUIDv7.generate(), identityID: UUID? = nil, displayName: String, position: Int) {
        self.id = id
        self.identityID = identityID
        self.displayName = displayName
        self.position = position
    }
}

/// ツアー（`contract-mapping.md` §3.5）。作成は `POST /v1/applications` の find-or-create のみ。
public struct Tour: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var artistNameRaw: String
    public var updatedAt: Date

    public init(id: UUID = UUIDv7.generate(), name: String, artistNameRaw: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.artistNameRaw = artistNameRaw
        self.updatedAt = updatedAt
    }
}

/// 公演。`EventKit.EKEvent` / `UIEvent` との混同回避のため `EventEntity`（`docs/05` §2.1）。
public struct EventEntity: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var tourID: UUID
    public var name: String
    public var venueNameRaw: String
    /// 公演日（date-only・JST 00:00）。**null がありうる**（E-8）
    public var eventDate: Date?
    /// 開演時刻（datetime）。`eventDate` とは別物
    public var startsAt: Date?
    public var updatedAt: Date

    public init(
        id: UUID = UUIDv7.generate(),
        tourID: UUID,
        name: String,
        venueNameRaw: String = "",
        eventDate: Date? = nil,
        startsAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.tourID = tourID
        self.name = name
        self.venueNameRaw = venueNameRaw
        self.eventDate = eventDate
        self.startsAt = startsAt
        self.updatedAt = updatedAt
    }
}

/// 申込（`contract-mapping.md` §3.4）。
/// 公演名・会場・アーティスト・公演日は持たず、`tourID` / `eventID` から引く（F5・F3）。
public struct ApplicationEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var tourID: UUID
    public var eventID: UUID
    public var repIdentityID: UUID
    /// FR-AP-7: 当面は常に nil を送る
    public var repMembershipID: UUID?
    public var roundName: String?
    public var appliedOn: Date?
    public var resultOn: Date?
    public var status: ApplicationStatus
    public var seatRaw: String
    public var ticketCount: Int
    public var priceYen: Int?
    public var companions: [Companion]
    public var note: String
    public var updatedAt: Date

    public init(
        id: UUID = UUIDv7.generate(),
        tourID: UUID,
        eventID: UUID,
        repIdentityID: UUID,
        repMembershipID: UUID? = nil,
        roundName: String? = nil,
        appliedOn: Date? = nil,
        resultOn: Date? = nil,
        status: ApplicationStatus = .applied,
        seatRaw: String = "",
        ticketCount: Int = 1,
        priceYen: Int? = nil,
        companions: [Companion] = [],
        note: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.tourID = tourID
        self.eventID = eventID
        self.repIdentityID = repIdentityID
        self.repMembershipID = repMembershipID
        self.roundName = roundName
        self.appliedOn = appliedOn
        self.resultOn = resultOn
        self.status = status
        self.seatRaw = seatRaw
        self.ticketCount = ticketCount
        self.priceYen = priceYen
        self.companions = companions
        self.note = note
        self.updatedAt = updatedAt
    }
}
