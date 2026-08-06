import Foundation

/// 共有ボードの中身。**`scope_type` によって items の形が完全に別物**（§4.8 P7）。
///
/// - `tour`: 公演 × 名義の行（`event_name` / `rep_name` / `status` / `seat` …）
/// - `identity_summary`: 名義ごとの件数（`name` / `visible` / `application_count` / `won_count`）
///
/// enum にすることで「identity_summary なのに tour の行を持つ」状態を型で作れなくする。
public enum SharedBoardContent: Equatable, Sendable {
    case tour([SharedBoardItem])
    case identitySummary([SharedIdentitySummaryItem])

    public var scopeType: ShareScope {
        switch self {
        case .tour: .tour
        case .identitySummary: .identitySummary
        }
    }

    public var isEmpty: Bool {
        switch self {
        case .tour(let rows): rows.isEmpty
        case .identitySummary(let rows): rows.isEmpty
        }
    }
}

/// 共有ボード（受け取り側）。**`ApplicationEntry` / `Identity` とは別系統の型**（§4.8 P6）。
/// 内部 UUID・会員番号・`identity_id` を含まない。
public struct SharedBoard: Equatable, Sendable {
    public let permission: SharePermission
    /// `scope_type == "tour"` のときだけ来る（identity_summary には `tour` キーが無い）
    public let tourName: String?
    public let artistName: String?
    public let generatedAt: Date
    public var content: SharedBoardContent

    /// 中身から導出する（保存しない）。`scopeType` と `content` がズレる状態を作れなくする。
    public var scopeType: ShareScope { content.scopeType }

    public init(
        permission: SharePermission,
        tourName: String? = nil,
        artistName: String? = nil,
        generatedAt: Date,
        content: SharedBoardContent
    ) {
        self.permission = permission
        self.tourName = tourName
        self.artistName = artistName
        self.generatedAt = generatedAt
        self.content = content
    }

    /// tour スコープ。
    public init(
        permission: SharePermission,
        tourName: String? = nil,
        artistName: String? = nil,
        generatedAt: Date,
        items: [SharedBoardItem]
    ) {
        self.init(
            permission: permission,
            tourName: tourName,
            artistName: artistName,
            generatedAt: generatedAt,
            content: .tour(items)
        )
    }

    /// identity_summary スコープ（`tour` キーは来ない。書き込みも無い）。
    public init(
        permission: SharePermission = .read,
        generatedAt: Date,
        identities: [SharedIdentitySummaryItem]
    ) {
        self.init(
            permission: permission,
            tourName: nil,
            artistName: nil,
            generatedAt: generatedAt,
            content: .identitySummary(identities)
        )
    }

    /// tour スコープの行。**identity_summary では常に空**（別系統の型なので変換しない）。
    public var items: [SharedBoardItem] {
        get {
            if case .tour(let rows) = content { return rows }
            return []
        }
        set {
            // identity_summary のボードに tour の行を後から生やさない
            guard case .tour = content else { return }
            content = .tour(newValue)
        }
    }

    /// identity_summary スコープの行。**tour では常に空**。
    public var identitySummaries: [SharedIdentitySummaryItem] {
        if case .identitySummary(let rows) = content { return rows }
        return []
    }

    /// 画面見出し / 保存した token の一覧に使う表示名。
    /// identity_summary には tour 名が無いのでスコープ名を出す。
    public var displayTitle: String? {
        switch content {
        case .tour: tourName
        case .identitySummary: "名義まとめ"
        }
    }
}

/// identity_summary スコープの 1 行（`api-contract.md` §8 / `public-share.presenter.ts`）。
///
/// `visible: false`（`identities.history_visible = false`）の名義は
/// **件数キー自体がレスポンスに含まれない**。件数が無い状態を `counts == nil` で表す。
public struct SharedIdentitySummaryItem: Equatable, Sendable, Identifiable {
    /// レスポンス内の並び順。同名の名義があっても id を一意にするために持つ
    public let rowIndex: Int
    public let name: String
    /// nil = 非公開（件数を出さない）。**0 件と混同しない**
    public let counts: SharedIdentityCounts?

    public init(rowIndex: Int, name: String, counts: SharedIdentityCounts?) {
        self.rowIndex = rowIndex
        self.name = name
        self.counts = counts
    }

    public var isVisible: Bool { counts != nil }

    public var id: String { "#\(rowIndex)|\(name)" }
}

/// `visible: true` のときだけ存在する件数。**片方だけ存在する状態を型で作れなくする**。
public struct SharedIdentityCounts: Equatable, Sendable {
    public let applicationCount: Int
    public let wonCount: Int

    public init(applicationCount: Int, wonCount: Int) {
        self.applicationCount = applicationCount
        self.wonCount = wonCount
    }

    /// 2 つ揃ったときだけ生成される（片方欠けは nil = 非公開扱い）。
    public init?(applicationCount: Int?, wonCount: Int?) {
        guard let applicationCount, let wonCount else { return nil }
        self.applicationCount = applicationCount
        self.wonCount = wonCount
    }
}

public struct SharedBoardItem: Equatable, Sendable, Identifiable {
    /// レスポンス内の並び順。read リンクには `item_key` が無いため id の一部に使う
    public var rowIndex: Int
    public var eventName: String
    public var venue: String?
    public var eventDate: Date?
    public var roundName: String?
    public var repName: String
    public var repColor: String?
    public var companions: [String]
    public var status: ApplicationStatus
    /// `null` / 空文字 / 文字列の 3 状態を保つ（P5）
    public var seat: String?
    /// nil = read リンク、または編集不可の行（**`editable ?? true` にしない** — P1）
    public var handle: SharedItemHandle?

    public init(
        rowIndex: Int,
        eventName: String,
        venue: String? = nil,
        eventDate: Date? = nil,
        roundName: String? = nil,
        repName: String,
        repColor: String? = nil,
        companions: [String] = [],
        status: ApplicationStatus,
        seat: String? = nil,
        handle: SharedItemHandle? = nil
    ) {
        self.rowIndex = rowIndex
        self.eventName = eventName
        self.venue = venue
        self.eventDate = eventDate
        self.roundName = roundName
        self.repName = repName
        self.repColor = repColor
        self.companions = companions
        self.status = status
        self.seat = seat
        self.handle = handle
    }

    /// `item_key` はリンク内で一意な不透明値なので、そのまま `id` に使ってよい（P3）。
    ///
    /// read リンクには `item_key` が無い。行の内容だけでは一意にならない
    /// （同一公演・同一名義でラウンド違いの申込が並ぶ / 非公開名義は `rep_name` が全て同じ文字列にマスクされる）ため、
    /// **レスポンス内の並び順を先頭に足す**。`ForEach` の id 重複を防ぐ。
    public var id: String {
        if let itemKey = handle?.itemKey { return itemKey }
        return "#\(rowIndex)|\(eventName)|\(roundName ?? "")|\(repName)"
    }
}

/// `itemKey` / `rev` / `editable` の 3 つで 1 単位（§4.8 P2）。
/// 「itemKey はあるが rev が無い」という不整合状態を型で作れなくする。
public struct SharedItemHandle: Equatable, Sendable {
    public let itemKey: String
    public let rev: String
    public let editable: Bool

    public init(itemKey: String, rev: String, editable: Bool) {
        self.itemKey = itemKey
        self.rev = rev
        self.editable = editable
    }

    /// 3 つ揃ったときだけ生成される（片方欠けは nil）。
    public init?(itemKey: String?, rev: String?, editable: Bool?) {
        guard let itemKey, let rev, let editable else { return nil }
        self.itemKey = itemKey
        self.rev = rev
        self.editable = editable
    }
}

/// `CONFLICT` 409 の `details.current`。
public struct SharedItemSnapshot: Equatable, Sendable {
    public let status: ApplicationStatus
    public let seat: String?
    public let rev: String

    public init(status: ApplicationStatus, seat: String?, rev: String) {
        self.status = status
        self.seat = seat
        self.rev = rev
    }
}

/// `PATCH /public/shares/:token/items/:item_key` の変更内容。
/// **空ボディ（`status` も `seat` も無い）を型で作れなくする**（§4.8）。
public enum SharedItemChange: Equatable, Sendable {
    case status(ApplicationStatus)
    /// nil = 明示的な `null`（空文字は空文字のまま送る）
    case seat(String?)
    case statusAndSeat(ApplicationStatus, String?)

    public var status: ApplicationStatus? {
        switch self {
        case .status(let value): value
        case .seat: nil
        case .statusAndSeat(let value, _): value
        }
    }

    public var hasSeat: Bool {
        switch self {
        case .status: false
        case .seat, .statusAndSeat: true
        }
    }

    public var seat: String?? {
        switch self {
        case .status: nil
        case .seat(let value): .some(value)
        case .statusAndSeat(_, let value): .some(value)
        }
    }
}
