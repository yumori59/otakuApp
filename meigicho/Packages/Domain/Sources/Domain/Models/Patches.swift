import Foundation

/// PATCH の差分。`Patchable` で「送らない」と「`null` を送る」を区別する（`contract-mapping.md` §1.2）。
public struct IdentityPatch: Equatable, Sendable {
    public var displayName: Patchable<String> = .unchanged
    public var relation: Patchable<Relation> = .unchanged
    public var colorHex: Patchable<String> = .unchanged
    public var joinedOn: Patchable<Date> = .unchanged
    public var note: Patchable<String> = .unchanged
    public var historyVisible: Patchable<Bool> = .unchanged
    public var sortOrder: Patchable<Int> = .unchanged

    public init() {}
}

public struct MembershipPatch: Equatable, Sendable {
    public var identityID: Patchable<UUID> = .unchanged
    public var fanClubNameRaw: Patchable<String> = .unchanged
    public var memberNoLast4: Patchable<String> = .unchanged
    public var rank: Patchable<String> = .unchanged
    public var renewalOn: Patchable<Date> = .unchanged
    public var feeYen: Patchable<Int> = .unchanged
    public var autoRenew: Patchable<Bool> = .unchanged
    public var note: Patchable<String> = .unchanged

    public init() {}
}

public struct ApplicationPatch: Equatable, Sendable {
    public var repIdentityID: Patchable<UUID> = .unchanged
    public var repMembershipID: Patchable<UUID> = .unchanged
    public var roundName: Patchable<String> = .unchanged
    public var appliedOn: Patchable<Date> = .unchanged
    public var resultOn: Patchable<Date> = .unchanged
    public var status: Patchable<ApplicationStatus> = .unchanged
    public var seatRaw: Patchable<String> = .unchanged
    public var ticketCount: Patchable<Int> = .unchanged
    public var priceYen: Patchable<Int> = .unchanged
    public var note: Patchable<String> = .unchanged
    /// 送るときは**全置換**（`id` / `position` 付き）
    public var companions: Patchable<[Companion]> = .unchanged

    public init() {}
}

public struct TourPatch: Equatable, Sendable {
    public var name: Patchable<String> = .unchanged
    public var artistNameRaw: Patchable<String> = .unchanged

    public init() {}
}

public struct EventPatch: Equatable, Sendable {
    public var name: Patchable<String> = .unchanged
    public var venueNameRaw: Patchable<String> = .unchanged
    public var eventDate: Patchable<Date> = .unchanged
    public var startsAt: Patchable<Date> = .unchanged

    public init() {}
}

/// `PATCH /v1/me`。**`account_id` / `plan` / `id` を持たない**（送ると 400 = C6）。
public struct ProfilePatch: Equatable, Sendable {
    public var displayName: Patchable<String> = .unchanged
    public var username: Patchable<String> = .unchanged
    public var appDisplayName: Patchable<String> = .unchanged
    public var themeColor: Patchable<String> = .unchanged
    public var locale: Patchable<String> = .unchanged
    public var timezone: Patchable<String> = .unchanged
    public var onboardedAt: Patchable<Date> = .unchanged

    public init() {}
}
