import Foundation
import Core
import Domain

// `contract-mapping.md` §4.4。
// **`member_no` / `member_no_cipher` は型として定義しない**（送ると 400。§4.4）。

// MARK: - Response

struct MembershipListResponse: Decodable, Sendable {
    let items: [MembershipResponse]
}

struct MembershipResponse: Decodable, Sendable {
    let id: UUID
    let identityID: UUID
    let fanClubNameRaw: String
    let memberNoLast4: String?
    let rank: String?
    let renewalOn: String?
    let feeYen: Int?
    let autoRenew: Bool
    let note: String?
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case identityID = "identity_id"
        case fanClubNameRaw = "fan_club_name_raw"
        case memberNoLast4 = "member_no_last4"
        case rank
        case renewalOn = "renewal_on"
        case feeYen = "fee_yen"
        case autoRenew = "auto_renew"
        case note
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

// MARK: - Request

/// `POST /v1/memberships`。**`member_no` / `member_no_cipher` は持たない**（送ると 400）。
struct CreateMembershipRequest: Encodable, Sendable {
    let id: UUID
    let identityID: UUID
    let fanClubNameRaw: String
    let memberNoLast4: String?
    let rank: String?
    let renewalOn: String?
    let feeYen: Int?
    let autoRenew: Bool
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case identityID = "identity_id"
        case fanClubNameRaw = "fan_club_name_raw"
        case memberNoLast4 = "member_no_last4"
        case rank
        case renewalOn = "renewal_on"
        case feeYen = "fee_yen"
        case autoRenew = "auto_renew"
        case note
    }
}

/// `PATCH /v1/memberships/:id`（`identity_id` の付け替え可）。
struct UpdateMembershipRequest: Encodable, Sendable {
    var identityID: Patchable<UUID> = .unchanged
    var fanClubNameRaw: Patchable<String> = .unchanged
    var memberNoLast4: Patchable<String> = .unchanged
    var rank: Patchable<String> = .unchanged
    var renewalOn: Patchable<Date> = .unchanged
    var feeYen: Patchable<Int> = .unchanged
    var autoRenew: Patchable<Bool> = .unchanged
    var note: Patchable<String> = .unchanged

    enum CodingKeys: String, CodingKey {
        case identityID = "identity_id"
        case fanClubNameRaw = "fan_club_name_raw"
        case memberNoLast4 = "member_no_last4"
        case rank
        case renewalOn = "renewal_on"
        case feeYen = "fee_yen"
        case autoRenew = "auto_renew"
        case note
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodePatch(identityID, forKey: .identityID)
        try container.encodePatch(fanClubNameRaw, forKey: .fanClubNameRaw)
        try container.encodePatch(memberNoLast4, forKey: .memberNoLast4)
        try container.encodePatch(rank, forKey: .rank)
        try container.encodePatch(renewalOn, forKey: .renewalOn) { APIDateFormat.dateOnlyString(from: $0) }
        try container.encodePatch(feeYen, forKey: .feeYen)
        try container.encodePatch(autoRenew, forKey: .autoRenew)
        try container.encodePatch(note, forKey: .note)
    }
}

// MARK: - Domain へのマッピング

extension MembershipResponse {
    func toDomain() -> Membership {
        Membership(
            id: id,
            identityID: identityID,
            fanClubNameRaw: fanClubNameRaw,
            memberNoLast4: memberNoLast4,
            rank: rank,
            renewalOn: renewalOn.flatMap { APIDateFormat.dateOnly(from: $0) },
            feeYen: feeYen,
            autoRenew: autoRenew,
            note: note ?? ""
        )
    }
}

extension Membership {
    /// `POST /v1/memberships` の本文。
    func toCreateRequest() -> CreateMembershipRequest {
        CreateMembershipRequest(
            id: id,
            identityID: identityID,
            fanClubNameRaw: fanClubNameRaw,
            memberNoLast4: memberNoLast4,
            rank: rank,
            renewalOn: renewalOn.map { APIDateFormat.dateOnlyString(from: $0) },
            feeYen: feeYen,
            autoRenew: autoRenew,
            note: note.isEmpty ? nil : note
        )
    }
}

extension MembershipPatch {
    /// `PATCH /v1/memberships/:id` の本文。
    func toRequest() -> UpdateMembershipRequest {
        var request = UpdateMembershipRequest()
        request.identityID = identityID
        request.fanClubNameRaw = fanClubNameRaw
        request.memberNoLast4 = memberNoLast4
        request.rank = rank
        request.renewalOn = renewalOn
        request.feeYen = feeYen
        request.autoRenew = autoRenew
        switch note {
        case .unchanged:
            request.note = .unchanged
        case .set(let value):
            request.note = .set((value?.isEmpty ?? true) ? nil : value)
        }
        return request
    }
}
