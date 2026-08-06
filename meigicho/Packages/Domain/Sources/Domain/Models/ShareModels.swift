import Foundation

/// 共有リンク（オーナー側）。
/// **`token` / `url` は持たない。** 発行レスポンスにしか存在しないため `IssuedShareLink` で受け取る（C4）。
public struct ShareLink: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var scopeType: ShareScope
    public var scopeID: UUID?
    public var scopeName: String?
    public var permission: SharePermission
    public var maskMemberNo: Bool
    public var sharedWithAccountIDs: [String]
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
        sharedWithAccountIDs: [String] = [],
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
        self.sharedWithAccountIDs = sharedWithAccountIDs
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
