import Foundation

/// `POST /v1/auth/*` が返すユーザー情報。
public struct SignedInUser: Equatable, Sendable {
    public let id: UUID
    public let accountID: String?
    public let displayName: String?
    public let plan: Plan
    public let isNew: Bool

    public init(id: UUID, accountID: String?, displayName: String?, plan: Plan, isNew: Bool) {
        self.id = id
        self.accountID = accountID
        self.displayName = displayName
        self.plan = plan
        self.isNew = isNew
    }
}

/// アクセストークン + リフレッシュトークン。
/// `refresh` は**回転式**なので、返ってきた値で必ず保存し直す。
public struct TokenPair: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    /// 受信時刻 + (`expires_in` - 60秒マージン)
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public struct AuthSession: Equatable, Sendable {
    public let tokens: TokenPair
    public let user: SignedInUser

    public init(tokens: TokenPair, user: SignedInUser) {
        self.tokens = tokens
        self.user = user
    }

    public var accessToken: String { tokens.accessToken }
    public var refreshToken: String { tokens.refreshToken }
    public var expiresAt: Date { tokens.expiresAt }
}

/// `GET /v1/me` の `profile` + `user`（`contract-mapping.md` §4.2）。
public struct UserProfile: Equatable, Sendable {
    public let userID: UUID
    public var accountID: String?
    public var displayName: String?
    public var username: String?
    public var appDisplayName: String?
    public var themeColor: String
    public var locale: String
    public var timezone: String
    public var onboardedAt: Date?
    public var email: String?
    /// `"apple"` / `"google"` / `"email"`。**未知の値が増えてもクラッシュしない**ため `[String]` のまま持つ
    public var authProviders: [String]

    public init(
        userID: UUID,
        accountID: String? = nil,
        displayName: String? = nil,
        username: String? = nil,
        appDisplayName: String? = nil,
        themeColor: String,
        locale: String,
        timezone: String,
        onboardedAt: Date? = nil,
        email: String? = nil,
        authProviders: [String] = []
    ) {
        self.userID = userID
        self.accountID = accountID
        self.displayName = displayName
        self.username = username
        self.appDisplayName = appDisplayName
        self.themeColor = themeColor
        self.locale = locale
        self.timezone = timezone
        self.onboardedAt = onboardedAt
        self.email = email
        self.authProviders = authProviders
    }

    /// パスワード変更 UI を出してよいか（`auth_providers` に `"email"` があるときだけ）。
    public var hasPasswordLogin: Bool { authProviders.contains("email") }
}

/// `GET /v1/me` の `entitlement`。`identityLimit` / `shareLimit` の nil は**無制限**。
public struct Entitlement: Equatable, Sendable {
    public var plan: Plan
    public var expiresAt: Date?
    public var inGracePeriod: Bool
    public var bonusIdentitySlots: Int
    public var bonusExpiresAt: Date?
    public var identityLimit: Int?
    public var shareLimit: Int?

    public init(
        plan: Plan,
        expiresAt: Date? = nil,
        inGracePeriod: Bool = false,
        bonusIdentitySlots: Int = 0,
        bonusExpiresAt: Date? = nil,
        identityLimit: Int? = nil,
        shareLimit: Int? = nil
    ) {
        self.plan = plan
        self.expiresAt = expiresAt
        self.inGracePeriod = inGracePeriod
        self.bonusIdentitySlots = bonusIdentitySlots
        self.bonusExpiresAt = bonusExpiresAt
        self.identityLimit = identityLimit
        self.shareLimit = shareLimit
    }
}

public struct MeSnapshot: Equatable, Sendable {
    public var profile: UserProfile
    public var entitlement: Entitlement

    public init(profile: UserProfile, entitlement: Entitlement) {
        self.profile = profile
        self.entitlement = entitlement
    }
}
