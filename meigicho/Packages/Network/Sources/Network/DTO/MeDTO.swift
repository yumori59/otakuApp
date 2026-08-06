import Foundation
import Core
import Domain

// `GET /v1/me` / `PATCH /v1/me`（`contract-mapping.md` §4.2 / `api-contract.md` §2）。
// **`account_id` / `plan` / `id` は Request DTO に定義しない**（`forbidNonWhitelisted` で 400 = C6 / AC-ME-03）。

// MARK: - Response

struct MeResponse: Decodable, Sendable {
    let user: MeUserResponse
    let profile: MeProfileResponse
    let entitlement: MeEntitlementResponse
}

struct MeUserResponse: Decodable, Sendable {
    let id: UUID
    let email: String?
    /// `"apple"` / `"google"` / `"email"`。**未知の値が増えてもクラッシュしない**ため `[String]` のまま持つ
    /// （`api-contract-delta.md` §2 で導出規則が `password_hash` に変わった。キー・型は不変）
    let authProviders: [String]
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case authProviders = "auth_providers"
        case createdAt = "created_at"
    }
}

struct MeProfileResponse: Decodable, Sendable {
    let accountID: String?
    let displayName: String?
    let username: String?
    let appDisplayName: String?
    let themeColor: String
    let locale: String
    let timezone: String
    let onboardedAt: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case displayName = "display_name"
        case username
        case appDisplayName = "app_display_name"
        case themeColor = "theme_color"
        case locale
        case timezone
        case onboardedAt = "onboarded_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// `identity_limit` / `share_limit` の `null` は**無制限**（`plus`）。
struct MeEntitlementResponse: Decodable, Sendable {
    let plan: String
    let expiresAt: String?
    let inGracePeriod: Bool
    let bonusIdentitySlots: Int
    let bonusExpiresAt: String?
    let identityLimit: Int?
    let shareLimit: Int?

    enum CodingKeys: String, CodingKey {
        case plan
        case expiresAt = "expires_at"
        case inGracePeriod = "in_grace_period"
        case bonusIdentitySlots = "bonus_identity_slots"
        case bonusExpiresAt = "bonus_expires_at"
        case identityLimit = "identity_limit"
        case shareLimit = "share_limit"
    }
}

// MARK: - Request

/// `PATCH /v1/me`。**送られたキーのみ更新**されるので `Patchable` で省略と `null` を区別する（§1.2）。
///
/// `CodingKeys` に `account_id` / `plan` / `id` が**存在しない**ことが AC-ME-03 の実体。
struct UpdateMeRequest: Encodable, Sendable {
    let patch: ProfilePatch

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
        case appDisplayName = "app_display_name"
        case themeColor = "theme_color"
        case locale
        case timezone
        case onboardedAt = "onboarded_at"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodePatch(patch.displayName, forKey: .displayName)
        try container.encodePatch(patch.username, forKey: .username)
        try container.encodePatch(patch.appDisplayName, forKey: .appDisplayName)
        try container.encodePatch(patch.themeColor, forKey: .themeColor)
        try container.encodePatch(patch.locale, forKey: .locale)
        try container.encodePatch(patch.timezone, forKey: .timezone)
        // datetime は ISO8601 UTC ミリ秒（§2.1）
        try container.encodePatch(patch.onboardedAt, forKey: .onboardedAt) {
            APIDateFormat.dateTimeString(from: $0)
        }
    }
}

// MARK: - Domain へのマッピング

extension MeResponse {
    func toDomain() -> MeSnapshot {
        MeSnapshot(
            profile: UserProfile(
                userID: user.id,
                accountID: profile.accountID,
                displayName: profile.displayName,
                username: profile.username,
                appDisplayName: profile.appDisplayName,
                themeColor: profile.themeColor,
                locale: profile.locale,
                timezone: profile.timezone,
                onboardedAt: profile.onboardedAt.flatMap(APIDateFormat.dateTime(from:)),
                email: user.email,
                authProviders: user.authProviders
            ),
            entitlement: Entitlement(
                plan: MePlan.plan(from: entitlement.plan),
                expiresAt: entitlement.expiresAt.flatMap(APIDateFormat.dateTime(from:)),
                inGracePeriod: entitlement.inGracePeriod,
                bonusIdentitySlots: entitlement.bonusIdentitySlots,
                bonusExpiresAt: entitlement.bonusExpiresAt.flatMap(APIDateFormat.dateTime(from:)),
                identityLimit: entitlement.identityLimit,
                shareLimit: entitlement.shareLimit
            )
        )
    }
}

/// 未知の plan でプロフィール取得を落とさない。**フォールバックした事実はログに残す**（BE-2 の iOS 版）。
enum MePlan {
    static func plan(from raw: String) -> Plan {
        guard let plan = Plan(rawValue: raw) else {
            AppLogger(category: "me").unknownValue(field: "plan", rawValue: raw)
            return .free
        }
        return plan
    }
}
