import Foundation

/// 共有リンクの招待先 1 件（`api-contract-delta.md` §1 / §2 の `recipients[]`）。
///
/// 招待は**アクセス制限そのもの**。ここに載っているアカウントだけが共有を開ける
/// （旧「記録用メタ `shared_with_account_ids`」は廃止された）。
///
/// - `accountID` が一意キー。**内部 UUID はレスポンスに現れない**（オーナーにも受け取り側にも出さない）
/// - `hiddenAt` は**存在しない**。受け取り側の非表示はオーナーに見せない（Q3）
public struct ShareRecipient: Identifiable, Equatable, Sendable {
    /// `ACC-XXXXXX`（`AccountIDValidator` の形式）
    public let accountID: String
    /// 相手のプロフィール表示名。未設定なら nil
    public var displayName: String?
    public var invitedAt: Date
    /// 相手が最後に board を開いた時刻。一度も開いていなければ nil
    public var lastViewedAt: Date?

    public init(
        accountID: String,
        displayName: String? = nil,
        invitedAt: Date,
        lastViewedAt: Date? = nil
    ) {
        self.accountID = accountID
        self.displayName = displayName
        self.invitedAt = invitedAt
        self.lastViewedAt = lastViewedAt
    }

    public var id: String { accountID }

    /// 一覧に出す名前。表示名が無ければ ACC-ID をそのまま出す（誰を招待したか分からなくなるのを防ぐ）。
    public var displayLabel: String {
        guard let displayName, !displayName.isEmpty else { return accountID }
        return displayName
    }

    /// まだ一度も開いていない。
    public var hasNeverViewed: Bool { lastViewedAt == nil }
}

/// 共有リンク（オーナー側）。
/// **`token` / `url` は持たない。** 発行レスポンスにしか存在しないため `IssuedShareLink` で受け取る（C4）。
public struct ShareLink: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var scopeType: ShareScope
    public var scopeID: UUID?
    public var scopeName: String?
    public var permission: SharePermission
    public var maskMemberNo: Bool
    /// 招待済みアカウント。**1 件以上必須**（0 件のリンクは誰も開けない = 実質失効）。
    /// 旧 `sharedWithAccountIDs: [String]` の置き換え。二重管理を避けるため文字列配列は持たない
    public var recipients: [ShareRecipient]
    public var expiresAt: Date?
    public var revokedAt: Date?
    public var viewCount: Int
    public var lastViewedAt: Date?
    public var editCount: Int
    public var lastEditedAt: Date?
    public var createdAt: Date
    public var isActive: Bool

    public init(
        id: UUID,
        scopeType: ShareScope,
        scopeID: UUID? = nil,
        scopeName: String? = nil,
        permission: SharePermission = .read,
        maskMemberNo: Bool = true,
        recipients: [ShareRecipient] = [],
        expiresAt: Date? = nil,
        revokedAt: Date? = nil,
        viewCount: Int = 0,
        lastViewedAt: Date? = nil,
        editCount: Int = 0,
        lastEditedAt: Date? = nil,
        createdAt: Date,
        isActive: Bool
    ) {
        self.id = id
        self.scopeType = scopeType
        self.scopeID = scopeID
        self.scopeName = scopeName
        self.permission = permission
        self.maskMemberNo = maskMemberNo
        self.recipients = recipients
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
        self.viewCount = viewCount
        self.lastViewedAt = lastViewedAt
        self.editCount = editCount
        self.lastEditedAt = lastEditedAt
        self.createdAt = createdAt
        self.isActive = isActive
    }
}

/// 発行直後だけ受け取れる token / url 付きの共有リンク。
///
/// `url` は **`meigicho://share/<token>` のカスタムスキーム**（`api-contract-delta.md` §1）。
/// 公開 Web 経路（`https://.../s/<token>`）は廃止されたので、この URL はアプリでしか開けない。
/// 開いた先で `redeem` が招待済みかどうかを判定する。
public struct IssuedShareLink: Equatable, Sendable {
    public let link: ShareLink
    public let token: String
    public let url: String

    public init(link: ShareLink, token: String, url: String) {
        self.link = link
        self.token = token
        self.url = url
    }
}

/// 共有スコープの選択。
/// `identitySummary` からは `scope_id` / `permission` のキー自体が生成されない（§4.7）。
public enum ShareScopeSelection: Equatable, Sendable {
    case tour(UUID, permission: SharePermission)
    case identitySummary

    public var scopeType: ShareScope {
        switch self {
        case .tour: .tour
        case .identitySummary: .identitySummary
        }
    }

    public var scopeID: UUID? {
        switch self {
        case .tour(let id, _): id
        case .identitySummary: nil
        }
    }

    public var permission: SharePermission? {
        switch self {
        case .tour(_, let permission): permission
        case .identitySummary: nil
        }
    }
}

/// 共有相手のアカウント ID（`^ACC-[0-9A-F]{6}$`・最大 20 件）。
public enum AccountIDValidator {
    public static let maxRecipients = 20

    public static func isValid(_ value: String) -> Bool {
        guard value.count == 10, value.hasPrefix("ACC-") else { return false }
        let suffix = value.dropFirst(4)
        return suffix.allSatisfy { $0.isNumber || ("A"..."F").contains(String($0)) }
    }

    /// 入力欄の文字列を分割する（区切りは `,` / `、` / 空白 / 改行 / タブ）。
    public static func parse(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",、 \n\t"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
