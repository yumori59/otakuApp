import Foundation

// 受信箱（**自分が招待された共有**）の型。`api-contract-delta.md` §4.1。
//
// このファイルが知っていること:
// - 受け取り側は**必ず自分のアカウントでログインしている**。共有は `share_id` で addressing する
// - `GET /v1/shares/received` は**意図的に情報を絞っている**。`token` / `scope_id` /
//   オーナーの内部 UUID / 他の招待者 / 会員番号 / 申込の中身は**来ない**（NFR-1 / AC-SI-45）。
//   ここに無いフィールドを「あとで足す」前に契約を確認すること

/// 受信箱に出す共有 1 件。
public struct SharedInboxItem: Identifiable, Equatable, Sendable {
    /// board を開くときの唯一の addressing キー。**token は受信箱に現れない**
    public let shareID: UUID
    public let scopeType: ShareScope
    /// ツアー名、または `identity_summary` の固定文言（サーバーが決める。クライアントで組み立てない）。
    /// **null を許す** — 共有元 tour を解決できない場合にサーバーが null を返す
    /// （`received-share.presenter.ts` の `resolveScopeName`）。1 件の欠損で一覧全体の
    /// デコードを落とさない（IOS-2）
    public let scopeName: String?
    public let permission: SharePermission
    public let owner: SharedInboxOwner
    public let invitedAt: Date
    public let expiresAt: Date?
    /// 招待されてから一度も開いていない / オーナーが更新した後に開いていない。
    /// **判定はサーバー**（`last_viewed_at` と `share_links.updated_at` の比較）
    public var unread: Bool

    public init(
        shareID: UUID,
        scopeType: ShareScope,
        scopeName: String?,
        permission: SharePermission,
        owner: SharedInboxOwner,
        invitedAt: Date,
        expiresAt: Date? = nil,
        unread: Bool = false
    ) {
        self.shareID = shareID
        self.scopeType = scopeType
        self.scopeName = scopeName
        self.permission = permission
        self.owner = owner
        self.invitedAt = invitedAt
        self.expiresAt = expiresAt
        self.unread = unread
    }

    public var id: UUID { shareID }

    /// 一覧に出す見出し。サーバーが名前を解決できなかったときの代替文言。
    public var displayTitle: String { scopeName ?? "共有された表" }

    /// 編集できる共有か（`write` かつ tour スコープ。`identity_summary` に書き込み経路は無い）。
    public var isEditable: Bool { permission == .write && scopeType == .tour }
}

/// 共有のオーナー。**内部 UUID は来ない**（ACC-ID と表示名だけ）。
/// `accountID` / `displayName` はどちらも null になりうる（プロフィール未解決）。
public struct SharedInboxOwner: Equatable, Sendable {
    public let accountID: String?
    public let displayName: String?

    public init(accountID: String?, displayName: String? = nil) {
        self.accountID = accountID
        self.displayName = displayName
    }

    /// 表示名が無ければ ACC-ID をそのまま出す。どちらも無ければ固定文言。
    public var displayLabel: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let accountID, !accountID.isEmpty { return accountID }
        return "共有した人"
    }
}
