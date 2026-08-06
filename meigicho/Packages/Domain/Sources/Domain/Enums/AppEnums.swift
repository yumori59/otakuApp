import Foundation

/// 未知の生値を既定値にフォールバックしたことを**呼び出し側に伝える**ための戻り値（E-12 / AC-N-07-T）。
public struct DecodedEnum<Value: Sendable>: Sendable {
    public let value: Value
    public let didFallback: Bool
    public let rawValue: String

    public init(value: Value, didFallback: Bool, rawValue: String) {
        self.value = value
        self.didFallback = didFallback
        self.rawValue = rawValue
    }
}

public enum Relation: String, CaseIterable, Codable, Sendable {
    case `self` = "self"
    case family
    case friend
    case other

    public var label: String {
        switch self {
        case .self: "本人"
        case .family: "家族"
        case .friend: "友人"
        case .other: "その他"
        }
    }

    /// 未知値は `.other`。フォールバックした事実は戻り値に現れる。
    public static func decoded(_ raw: String) -> DecodedEnum<Relation> {
        if let value = Relation(rawValue: raw) {
            return DecodedEnum(value: value, didFallback: false, rawValue: raw)
        }
        return DecodedEnum(value: .other, didFallback: true, rawValue: raw)
    }
}

public enum ApplicationStatus: String, CaseIterable, Codable, Sendable {
    case draft
    case applied
    case won
    case lost
    case cancelled

    public var label: String {
        switch self {
        case .draft: "下書き"
        case .applied: "申込中"
        case .won: "当選"
        case .lost: "落選"
        case .cancelled: "取消"
        }
    }

    public var stampStatus: StampStatus {
        switch self {
        case .draft: .draft
        case .applied: .applied
        case .won: .won
        case .lost, .cancelled: .lost
        }
    }

    /// 未知値は `.applied`。フォールバックした事実は戻り値に現れる。
    public static func decoded(_ raw: String) -> DecodedEnum<ApplicationStatus> {
        if let value = ApplicationStatus(rawValue: raw) {
            return DecodedEnum(value: value, didFallback: false, rawValue: raw)
        }
        return DecodedEnum(value: .applied, didFallback: true, rawValue: raw)
    }
}

public enum StampStatus: Sendable {
    case draft, applied, won, lost
}

/// 課金プラン（`api-contract.md`）。
public enum Plan: String, Codable, Sendable {
    case free
    case plus
}

/// 共有のスコープ。
public enum ShareScope: String, Codable, Sendable {
    case tour
    case identitySummary = "identity_summary"
}

/// 共有リンクの権限（`api-contract-delta.md` §0）。
/// **未知値を作れる経路を持たない**（受信時に未知値なら失敗させる）。
public enum SharePermission: String, Codable, Sendable {
    case read
    case write

    public var label: String {
        switch self {
        case .read: "閲覧のみ"
        case .write: "編集も許可"
        }
    }
}

public enum IdentitySortOrder: String, CaseIterable, Sendable {
    case renewalSoon
    case mostWins
    case joinedOldest

    public var label: String {
        switch self {
        case .renewalSoon: "更新が近い順"
        case .mostWins: "当選が多い順"
        case .joinedOldest: "入会が古い順"
        }
    }
}

public enum ApplicationFilter: String, CaseIterable, Sendable {
    case all = "すべて"
    case draft = "下書き"
    case applied = "申込中"
    case won = "当選"
    case lost = "落選"
}

public enum ApplicationViewMode: String, Sendable {
    case list
    case tourTable
}
