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
    /// 当選したが入金（決済）がまだ。当選回数には含める（#21）。
    case wonUnpaid = "won_unpaid"
    case won
    case lost
    case cancelled

    public var label: String {
        switch self {
        case .draft: "下書き"
        case .applied: "申込中"
        case .wonUnpaid: "当選/未入金"
        case .won: "当選"
        case .lost: "落選"
        case .cancelled: "取消"
        }
    }

    /// 横幅の狭いセグメント / ボタン用。`wonUnpaid` だけ `label` より短い。
    public var shortLabel: String {
        switch self {
        case .wonUnpaid: "未入金"
        default: label
        }
    }

    public var stampStatus: StampStatus {
        switch self {
        case .draft: .draft
        case .applied: .applied
        case .wonUnpaid: .wonUnpaid
        case .won: .won
        case .lost, .cancelled: .lost
        }
    }

    /// 当選扱い（`won` / `wonUnpaid`）。当選回数・当選済みの今後の公演などの集計に使う。
    public var isWon: Bool {
        self == .won || self == .wonUnpaid
    }

    /// ツアー表のステータスセルをタップしたときの巡回順。
    /// **`cancelled` は入れない**（取消は詳細画面から行う操作で、誤タップで入ると戻しにくい）。
    private static let tapCycle: [ApplicationStatus] = [.draft, .applied, .wonUnpaid, .won, .lost]

    public var nextInTapCycle: ApplicationStatus {
        guard let index = Self.tapCycle.firstIndex(of: self) else { return .applied }
        return Self.tapCycle[(index + 1) % Self.tapCycle.count]
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
    case draft, applied, wonUnpaid, won, lost
}

/// 申込での自分の立場（#22）。`rep_identity_id` は常に「このアプリで追跡する自分の名義」で、
/// 実際に代表者として申し込んだか、同行者として参加したかを表す。
public enum ApplicationRole: String, CaseIterable, Codable, Sendable {
    case representative
    case companion

    public var label: String {
        switch self {
        case .representative: "代表者"
        case .companion: "同行者"
        }
    }

    /// 一覧行の小さなバッジ用。
    public var badgeLabel: String {
        switch self {
        case .representative: "代表"
        case .companion: "同行"
        }
    }

    /// 未知値は `.representative`（既存データの既定）。フォールバックした事実は戻り値に現れる。
    public static func decoded(_ raw: String) -> DecodedEnum<ApplicationRole> {
        if let value = ApplicationRole(rawValue: raw) {
            return DecodedEnum(value: value, didFallback: false, rawValue: raw)
        }
        return DecodedEnum(value: .representative, didFallback: true, rawValue: raw)
    }

    /// BE の `representative_name` 上限（`apps/api/src/applications/dto/identity-role.ts`）
    public static let maxRepresentativeNameLength = 100

    /// `representative_name` は `companion` のときだけ意味を持つ（BE も representative では null に正規化する）。
    /// 前後の空白を除き、空なら nil。
    public static func normalizedRepresentativeName(_ name: String?, role: ApplicationRole) -> String? {
        guard role == .companion, let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxRepresentativeNameLength))
    }
}

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
    case wonUnpaid = "未入金"
    case won = "当選"
    case lost = "落選"
}

public enum ApplicationViewMode: String, Sendable {
    case list
    case tourTable
}
