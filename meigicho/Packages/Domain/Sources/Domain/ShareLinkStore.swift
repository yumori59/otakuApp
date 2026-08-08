import Foundation
import Core

// 旧 `TourShareStore`（UserDefaults にモックの共有ペイロードを持つ暫定実装）の置き換え。
// **UserDefaults 永続化は廃止**し、共有リンクの正はサーバー（`GET /v1/shares`）だけになった（AC-SH-13）。
//
// オーナー側のツアー表は**常にローカルの申込データ**を描く。共有ペイロード
// （`GET /v1/shares/received/:id`）はオーナー側から取りに行かない（AC-SH-12）。
//
// 共有は**招待されたアカウントだけ**が開ける（`api-contract-delta.md` §1）。
// 招待は 1 件以上必須で、`recipients` がアクセス制限そのもの（記録用メタではない）。

/// 1 つのスコープ（ツアー / 名義サマリ）の共有状態。**3 状態**（`plan.md` §7.4-2）。
public enum ShareLinkState: Equatable, Sendable {
    /// まだ共有リンクを作っていない
    case unshared
    /// 有効な共有リンクがある
    case shared(ShareLink)
    /// 作ったが失効 / 期限切れになっている
    case ended(ShareLink)

    public var link: ShareLink? {
        switch self {
        case .unshared: nil
        case .shared(let link), .ended(let link): link
        }
    }

    public var isShared: Bool {
        if case .shared = self { return true }
        return false
    }
}

/// 共有リンク（オーナー側）のストア。
///
/// - 発行 / 一覧 / 失効の 3 本だけ。**`permission` を後から変える API は無い**ので、
///   変更したいときは失効させて発行し直す（`api-contract-delta.md` §3）
/// - `token` / `url` は発行レスポンスにしか無い（C4）。`lastIssued` に**その場限りで**持つ
/// - `permission: .write` の公演数上限（free = 3 公演）は**サーバーだけが判定する**。
///   ここで件数を数えて事前に弾かない（IOS-4 / AC-SH-10-M）
@MainActor
@Observable
public final class ShareLinkStore {
    /// `GET /v1/shares` の全件（失効済みを含む）。
    public private(set) var links: [ShareLink] = []
    public private(set) var state: LoadState = .idle
    /// 発行 / 失効の失敗。**一覧は消さず、この 1 行で伝える**（E-1 / Q11）。
    public var actionError: AppError?
    public private(set) var isSaving = false
    /// **発行直後だけ**受け取れる token / url。
    /// 再取得できない（`GET /v1/shares` は token を返さない）ので、コピーし終えたら捨てる。
    public private(set) var lastIssued: IssuedShareLink?

    private let repository: (any ShareRepository)?
    private let now: @Sendable () -> Date
    private let logger = AppLogger(category: "shares")

    /// 引数を省略した形は **Preview 専用**（ネットワークに触らない）。
    public init(
        repository: (any ShareRepository)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.now = now
    }

    // MARK: - 読み込み

    /// 共有リンク一覧を取り直す。失敗しても既読データは消さない（E-1）。
    public func load() async {
        guard let repository else { return }
        state = .loading
        do {
            links = try await repository.list()
            state = .loaded
        } catch {
            state = .failed(Self.appError(from: error))
        }
    }

    /// ログアウト時に呼ぶ（前のユーザーの共有リンクを残さない）。
    public func clear() {
        links = []
        state = .idle
        actionError = nil
        lastIssued = nil
    }

    public func clearIssued() {
        lastIssued = nil
    }

    public func clearActionError() {
        actionError = nil
    }

    /// 有効な共有リンク数（`share_limit` 判定用）。
    public func activeLinkCount() -> Int {
        links.filter(\.isActive).count
    }

    // MARK: - 参照

    /// ツアーの共有状態。
    public func shareState(forTour tourID: UUID) -> ShareLinkState {
        Self.shareState(in: links, scopeType: .tour, scopeID: tourID, at: now())
    }

    /// 名義サマリ（`identity_summary`）の共有状態。
    public var identitySummaryState: ShareLinkState {
        Self.shareState(in: links, scopeType: .identitySummary, scopeID: nil, at: now())
    }

    /// 共有相手の初期値（既存リンクに招待済みの ID）。
    public func recipientIDs(forTour tourID: UUID) -> [String] {
        shareState(forTour: tourID).link?.recipients.map(\.accountID) ?? []
    }

    /// 既存リンクの招待一覧（表示名付き）。
    public func recipients(forTour tourID: UUID) -> [ShareRecipient] {
        shareState(forTour: tourID).link?.recipients ?? []
    }

    /// スコープに対応する状態を選ぶ**純粋関数**。
    ///
    /// 有効なものが 1 本でもあれば `.shared`（複数あれば作成が新しい方）。
    /// 無ければ最後に作ったものを `.ended` として見せ、1 本も無ければ `.unshared`。
    public static func shareState(
        in links: [ShareLink],
        scopeType: ShareScope,
        scopeID: UUID?,
        at now: Date
    ) -> ShareLinkState {
        let scoped = links.filter { $0.scopeType == scopeType && $0.scopeID == scopeID }
        guard !scoped.isEmpty else { return .unshared }
        let sorted = scoped.sorted { $0.createdAt > $1.createdAt }
        if let active = sorted.first(where: { isActive($0, at: now) }) {
            return .shared(active)
        }
        return .ended(sorted[0])
    }

    /// サーバーの `is_active` を基準にしつつ、**取得後に期限が過ぎた場合も終了として扱う**（E-11）。
    /// `is_active` は `GET /v1/shares` を叩いた時点の判定なので、画面を開いたままだとずれる。
    public static func isActive(_ link: ShareLink, at now: Date) -> Bool {
        guard link.isActive, link.revokedAt == nil else { return false }
        guard let expiresAt = link.expiresAt else { return true }
        return expiresAt > now
    }

    // MARK: - 発行

    /// ツアーの共有リンクを発行する。
    ///
    /// `permission` は呼び出し側（UI）が **`.read` / `.write` から選ぶ**。省略経路を作らない
    /// ＝ 未知値を送れない（AC-SH-04-T）。
    @discardableResult
    public func createTourLink(
        tourID: UUID,
        permission: SharePermission,
        maskMemberNo: Bool = true,
        recipientIDs: [String] = []
    ) async -> IssuedShareLink? {
        await create(
            .tour(tourID, permission: permission),
            maskMemberNo: maskMemberNo,
            recipientIDs: recipientIDs
        )
    }

    /// 名義サマリの共有リンクを発行する。**`permission` は送らない**（`write` は tour 専用 = 400）。
    @discardableResult
    public func createIdentitySummaryLink(
        maskMemberNo: Bool = true,
        recipientIDs: [String] = []
    ) async -> IssuedShareLink? {
        await create(.identitySummary, maskMemberNo: maskMemberNo, recipientIDs: recipientIDs)
    }

    private func create(
        _ selection: ShareScopeSelection,
        maskMemberNo: Bool,
        recipientIDs: [String]
    ) async -> IssuedShareLink? {
        guard let repository else { return nil }
        // AC-SH-02-T: 形式が違う ID / 件数超過は**送る前に**弾く（400 を往復させない）。
        // **実在確認はしない**（できない）。存在しない ACC-ID はサーバーが
        // `.shareRecipientUnknown` で返す（IOS-4: クライアントで独自の制約を足さない）
        let validation = AccountIDValidator.validate(recipientIDs)
        guard case .valid(let ids) = validation else {
            logger.event("share_recipients_rejected")
            actionError = .validation(message: validation.reason)
            return nil
        }
        // 招待は 1 件以上必須（`api-contract-delta.md` §1）。0 件は誰も開けないリンクになるので
        // サーバーも 400 を返す。UI は 0 件で発行ボタンを無効にするが、ここでも止める
        guard !ids.isEmpty else {
            logger.event("share_recipients_empty")
            actionError = .validation(message: "shared_with_account_ids must contain at least one account id")
            return nil
        }

        isSaving = true
        defer { isSaving = false }
        do {
            let issued = try await repository.create(
                selection,
                maskMemberNo: maskMemberNo,
                sharedWithAccountIDs: ids
            )
            upsert(issued.link)
            lastIssued = issued
            actionError = nil
            return issued
        } catch {
            // PLAN_LIMIT_SHARE（本数）/ PLAN_LIMIT_SHARE_WRITE（公演数）もここに来る。
            // **文言化するだけで、次回から押させない細工はしない**（IOS-4）
            actionError = Self.appError(from: error)
            return nil
        }
    }

    // MARK: - 招待の追加・削除（発行後）

    /// 招待を追加する（`POST /v1/shares/:id/recipients`）。
    ///
    /// **サーバーの戻り値は追加後の全件**なので、手元の `recipients` はそれで置き換える（差分マージしない）。
    /// 既に招待済みの ID は冪等に無視される。
    @discardableResult
    public func addRecipients(shareID: UUID, accountIDs: [String]) async -> [ShareRecipient]? {
        guard let repository else { return nil }
        let validation = AccountIDValidator.validate(accountIDs)
        guard case .valid(let ids) = validation, !ids.isEmpty else {
            actionError = .validation(message: validation.reason)
            return nil
        }

        isSaving = true
        defer { isSaving = false }
        do {
            let recipients = try await repository.addRecipients(shareID: shareID, accountIDs: ids)
            replaceRecipients(shareID: shareID, with: recipients)
            actionError = nil
            return recipients
        } catch {
            // `.shareRecipientUnknown(accountIDs:)` はここに来る（どの ID が無いかは文言に載る）
            actionError = Self.appError(from: error)
            return nil
        }
    }

    /// 招待を外す（`DELETE /v1/shares/:id/recipients/:account_id`・冪等）。
    ///
    /// **最後の 1 人を外しても成功する**（以後そのリンクは誰も開けない）。UI 側で止めない。
    public func removeRecipient(shareID: UUID, accountID: String) async {
        guard let repository else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.removeRecipient(shareID: shareID, accountID: accountID)
            if let index = links.firstIndex(where: { $0.id == shareID }) {
                links[index].recipients.removeAll { $0.accountID == accountID }
            }
            actionError = nil
        } catch {
            actionError = Self.appError(from: error)
        }
    }

    private func replaceRecipients(shareID: UUID, with recipients: [ShareRecipient]) {
        guard let index = links.firstIndex(where: { $0.id == shareID }) else { return }
        links[index].recipients = recipients
    }

    // MARK: - 失効

    /// 共有を停止する（`DELETE /v1/shares/:id`・冪等）。
    /// 成功したら手元も `.ended` に落とす（再取得を待たない）。
    public func revoke(_ id: UUID) async {
        guard let repository else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await repository.revoke(id: id)
            markRevoked(id)
            if lastIssued?.link.id == id { lastIssued = nil }
            actionError = nil
        } catch {
            actionError = Self.appError(from: error)
        }
    }

    // MARK: - 内部

    private func upsert(_ link: ShareLink) {
        if let index = links.firstIndex(where: { $0.id == link.id }) {
            links[index] = link
        } else {
            links.insert(link, at: 0)
        }
    }

    private func markRevoked(_ id: UUID) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        links[index].revokedAt = now()
        links[index].isActive = false
    }

    static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "UNEXPECTED", message: nil)
    }
}

// MARK: - 共有相手 ID の検証

public extension AccountIDValidator {
    enum Validation: Equatable, Sendable {
        case valid([String])
        /// 形式が `^ACC-[0-9A-F]{6}$` でない ID がある
        case invalidFormat([String])
        /// 20 件を超えている
        case tooMany(Int)

        /// `AppError.validation(message:)` に載せる短い理由（DEBUG でだけ表示される）。
        public var reason: String? {
            switch self {
            case .valid: nil
            case .invalidFormat(let ids): "invalid account id: \(ids.joined(separator: ", "))"
            case .tooMany(let count): "too many recipients: \(count)"
            }
        }
    }

    /// 分割済みの ID 配列を検証する。**送信前に弾く**（§4.7）。
    static func validate(_ ids: [String]) -> Validation {
        let invalid = ids.filter { !isValid($0) }
        guard invalid.isEmpty else { return .invalidFormat(invalid) }
        guard ids.count <= maxRecipients else { return .tooMany(ids.count) }
        return .valid(ids)
    }

    /// 入力欄の文字列をそのまま検証する（分割 → 検証）。
    static func validate(raw: String) -> Validation {
        validate(parse(raw))
    }
}

// MARK: - 表示用（オーナー側の 1 行サマリ）

public extension ShareLink {
    /// `閲覧 3 回 ・ 編集 2 回`（AC-SH-07-M）。
    /// **`read` リンクでも編集回数を出す**（0 回であることが分かる方が誤解が少ない）。
    var accessCountsSummary: String {
        "閲覧 \(viewCount) 回 ・ 編集 \(editCount) 回"
    }

    var permissionLabel: String { permission.label }
}
