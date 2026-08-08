import Foundation
import Core

/// 受信箱（**自分が招待された共有**）のストア。`api-contract-delta.md` §4.1 / §4.4 / §4.5。
///
/// - 正はサーバー（`GET /v1/shares/received`）。**ローカル永続化しない**
/// - 失効・期限切れ・非表示・自分がオーナーのものはサーバー側で除外されて来る。
///   ここで再度フィルタしない（判定を二重に持つとサーバーとズレる）
/// - 読み込みに失敗しても**既に表示している一覧を消さない**（E-1）。エラーは `state` / `actionError` で伝える
@MainActor
@Observable
public final class SharedInboxStore {
    /// `GET /v1/shares/received` の全件（サーバーの並び順 = 招待が新しい順）。
    public private(set) var items: [SharedInboxItem] = []
    public private(set) var state: LoadState = .idle
    /// 非表示切替 / redeem の失敗。**一覧は消さず、この 1 行で伝える**。
    public var actionError: AppError?
    /// 非表示切替や redeem の実行中（二重タップ防止）。
    public private(set) var isMutating = false

    private let repository: (any SharedInboxRepository)?
    private let logger = AppLogger(category: "shared-inbox")

    /// 引数を省略した形は **Preview 専用**（ネットワークに触らない）。
    public init(repository: (any SharedInboxRepository)? = nil) {
        self.repository = repository
    }

    // MARK: - 参照

    /// 未読バッジ用の件数。
    public var unreadCount: Int { items.filter(\.unread).count }

    public var isEmpty: Bool { items.isEmpty }

    public func item(withID shareID: UUID) -> SharedInboxItem? {
        items.first { $0.shareID == shareID }
    }

    // MARK: - 読み込み

    /// 一覧を取り直す。失敗しても既読データは消さない（E-1）。
    public func load() async {
        guard let repository else { return }
        state = .loading
        do {
            items = try await repository.list()
            state = .loaded
        } catch {
            state = .failed(Self.appError(from: error))
        }
    }

    /// ログアウト時に呼ぶ（前のユーザーの受信箱を残さない）。
    public func clear() {
        items = []
        state = .idle
        actionError = nil
    }

    public func clearActionError() { actionError = nil }

    // MARK: - 非表示

    /// 受信箱から隠す / 戻す（`POST|DELETE /v1/shares/received/:id/hide`・冪等）。
    ///
    /// **オーナーには見えない**（Q3）。隠しても共有そのものは失効しない。
    /// 楽観的に一覧から外し、失敗したら元に戻す。
    public func setHidden(shareID: UUID, hidden: Bool) async {
        guard let repository, !isMutating else { return }
        let index = items.firstIndex { $0.shareID == shareID }
        let removed = index.map { items[$0] }

        isMutating = true
        defer { isMutating = false }
        if hidden, let index { items.remove(at: index) }

        do {
            try await repository.setHidden(shareID: shareID, hidden: hidden)
            actionError = nil
            // 「戻す」はサーバーに再度問い合わせないと並び位置が分からないので取り直す
            if !hidden { await load() }
        } catch {
            // 楽観的に消した行を戻す（消えたまま残ると二度と操作できない）
            if hidden, let removed, let index {
                items.insert(removed, at: min(index, items.count))
            }
            actionError = Self.appError(from: error)
        }
    }

    // MARK: - 未読

    /// board を開いたときに手元の未読を落とす（サーバーは `GET .../received/:id` の副作用で更新する）。
    /// **サーバーへの往復はしない**。次の `load()` で正に上書きされる。
    public func markRead(shareID: UUID) {
        guard let index = items.firstIndex(where: { $0.shareID == shareID }) else { return }
        items[index].unread = false
    }

    // MARK: - redeem

    /// ディープリンクの token を `share_id` に交換する（`POST /v1/shares/received/redeem`）。
    ///
    /// 失敗時は `actionError` に載せて nil を返す:
    /// - `.shareNotInvited` — 招待されていない（**契約上ここだけが存在を confirm する**）
    /// - `.shareInvalid` — 未知 / 失効 / 期限切れ（3 者を区別しない）
    public func redeem(token: String) async -> UUID? {
        guard let repository, !isMutating else { return nil }
        isMutating = true
        defer { isMutating = false }
        do {
            let shareID = try await repository.redeem(token: token)
            actionError = nil
            return shareID
        } catch {
            let appError = Self.appError(from: error)
            if case .shareNotInvited = appError { logger.event("shared_inbox_not_invited") }
            actionError = appError
            return nil
        }
    }

    static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "UNEXPECTED", message: nil)
    }
}
