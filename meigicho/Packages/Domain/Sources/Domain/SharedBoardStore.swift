import Foundation
import Core

// 共有ボード（受け取り側）。**Bearer 認証を使わない経路**（`contract-mapping.md` §4.8 / §5.1）。
//
// このファイルが知っていること:
// - 資格情報は URL 中の token だけ。自分のアカウントとは無関係
// - `item_key` / `rev` は不透明値。解釈も生成もしない
// - ボードの内容は**ローカル永続化しない**。保存するのは token と表示用の最小メタだけ

// MARK: - 受け取った共有 token の保管

/// Keychain に保存する 1 本の共有 token とその表示用メタ。
/// **表データは持たない**（`contract-mapping.md` §5.1）。
public struct SavedSharedBoard: Equatable, Sendable, Identifiable, Codable {
    public let token: String
    /// 一覧表示用のツアー名（取得できたときだけ）
    public var title: String?
    public var lastOpenedAt: Date?

    public init(token: String, title: String? = nil, lastOpenedAt: Date? = nil) {
        self.token = token
        self.title = title
        self.lastOpenedAt = lastOpenedAt
    }

    public var id: String { token }
}

/// 受け取った共有 token の保管先。
///
/// 実装は `Network` の `KeychainSharedBoardTokenStore`（**自分の refresh token とは別 service 名前空間**）。
/// `Domain` は `Foundation` しか import しないので、protocol だけをここに置く（NFR-5）。
public protocol SharedBoardTokenStoring: Sendable {
    func list() async -> [SavedSharedBoard]
    func save(_ board: SavedSharedBoard) async
    func remove(token: String) async
}

// MARK: - 共有リンクの URL から token を取り出す（純粋関数）

/// 共有リンクの入力（URL 貼り付け / カスタムスキーム）から token を取り出す。
///
/// **Universal Links は本計画のスコープ外**（`plan.md` §7.7）。ここでは
/// - カスタムスキーム `meigicho://share/<token>`
/// - 共有 URL（`https://.../s/<token>` / `https://.../public/shares/<token>` など）
/// - token そのものの貼り付け
/// の 3 通りを受ける。**token の中身は解釈しない**（不透明値）。
public enum SharedBoardLink {
    /// アプリのカスタムスキーム（`Info.plist` の `CFBundleURLSchemes`）。
    public static let scheme = "meigicho"
    /// カスタムスキームのホスト部（`meigicho://share/<token>`）。
    public static let host = "share"

    /// token として受け付ける文字。**ASCII の base64url だけ**（`api-contract-delta.md` §4）+ 念のため `=`。
    /// `CharacterSet.alphanumerics` は Unicode の文字（かな・漢字など）も含むので使わない。
    private static let tokenCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_="
    )

    /// 貼り付けられた文字列から token を取り出す。取り出せなければ nil。
    public static func token(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.scheme != nil {
            return token(from: url)
        }
        // URL でなければ token 直貼りとみなす
        return validated(trimmed)
    }

    /// URL から token を取り出す（`.onOpenURL` から呼ぶ）。
    public static func token(from url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        if url.scheme?.lowercased() == scheme {
            // meigicho://share/<token> — host が "share" のときだけ受ける
            guard url.host?.lowercased() == host else { return nil }
            return validated(components.first)
        }

        // http(s) の共有 URL。最後のパス要素を token とみなす。
        // `/public/shares/<token>` / `/s/<token>` のどちらでも同じ扱い
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return validated(components.last)
    }

    private static func validated(_ candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty, candidate.count <= 256 else { return nil }
        guard candidate.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }) else { return nil }
        return candidate
    }
}

// MARK: - Store

/// 共有ボード（受け取り側）のストア。
///
/// **`ApiClient` / `TokenStore` に一切触れない。** 401 での refresh / サイレントログアウトが
/// 起きる経路と配線で結ばない（`contract-mapping.md` §5.1 の理由 2 / AC-SB-13-M）。
@MainActor
@Observable
public final class SharedBoardStore {
    /// 現在開いているボード。**永続化しない**
    public private(set) var board: SharedBoard?
    public private(set) var state: LoadState = .idle
    /// `SHARE_INVALID` を受けた（この共有は終了している）
    public private(set) var isEnded = false
    /// ボード全体に出す 1 行メッセージ（レート制限など）
    public var actionError: AppError?
    /// 行ごとのメッセージ（`itemID` → 文言）。**その行にだけ出す**
    public private(set) var itemMessages: [String: String] = [:]
    /// 保存中の行（二重送信を防ぐ）
    public private(set) var savingItemIDs: Set<String> = []
    /// 現在開いている token（画面表示には使わない）
    public private(set) var openedToken: String?

    private let repository: (any SharedBoardRepository)?
    private let tokenStore: (any SharedBoardTokenStoring)?
    private let now: @Sendable () -> Date
    private let logger = AppLogger(category: "shared-board")

    /// 引数を省略した形は **Preview 専用**（ネットワークにも Keychain にも触らない）。
    public init(
        repository: (any SharedBoardRepository)? = nil,
        tokenStore: (any SharedBoardTokenStoring)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.tokenStore = tokenStore
        self.now = now
    }

    // MARK: - 表示用

    /// 編集 UI を出してよいか（リンク全体の権限）。
    /// **書き込みは tour スコープにしか無い**（identity_summary は常に閲覧のみ）。
    public var canEdit: Bool {
        guard let board, case .tour = board.content else { return false }
        return board.permission == .write
    }

    /// この行を編集してよいか。**`editable ?? true` にしない**（P1）。
    public func isEditable(_ item: SharedBoardItem) -> Bool {
        canEdit && item.handle?.editable == true
    }

    public func message(for item: SharedBoardItem) -> String? { itemMessages[item.id] }

    public func isSaving(_ item: SharedBoardItem) -> Bool { savingItemIDs.contains(item.id) }

    // MARK: - 取得

    /// token でボードを開く。成功したら token を Keychain に保存する。
    public func open(token: String) async {
        openedToken = token
        isEnded = false
        actionError = nil
        itemMessages = [:]
        state = .loading
        await load(token: token)
    }

    /// いま開いている token で取り直す（ユーザーの明示操作）。
    public func reload() async {
        guard let openedToken else { return }
        actionError = nil
        state = .loading
        await load(token: openedToken)
    }

    public func clearActionError() { actionError = nil }

    public func clearMessage(for item: SharedBoardItem) { itemMessages[item.id] = nil }

    /// 画面を閉じるときに呼ぶ。**表データをメモリにも残さない**。
    public func close() {
        board = nil
        state = .idle
        openedToken = nil
        isEnded = false
        actionError = nil
        itemMessages = [:]
        savingItemIDs = []
    }

    private func load(token: String) async {
        guard let repository else {
            state = .loaded
            return
        }
        do {
            let fetched = try await repository.fetchBoard(token: token)
            board = fetched
            state = .loaded
            await tokenStore?.save(
                SavedSharedBoard(token: token, title: fetched.displayTitle, lastOpenedAt: now())
            )
        } catch {
            let appError = Self.appError(from: error)
            if case .shareInvalid = appError {
                // トークンが未知 / 失効 / 期限切れ。**保存した token を破棄する**（AC-SB-11-M）
                await discardToken(token)
                board = nil
                isEnded = true
                state = .loaded
                return
            }
            // 読み込み済みの内容は消さない（E-1）
            state = .failed(appError)
        }
    }

    // MARK: - 編集

    /// 状況を変更する。
    public func setStatus(_ status: ApplicationStatus, for item: SharedBoardItem) async {
        await apply(.status(status), to: item) { row in row.status = status }
    }

    /// 座席を保存する。
    ///
    /// **空文字を `null` に丸めない**（P5）。呼び出し側が「消す = `null`」を意図するときだけ nil を渡す。
    public func saveSeat(_ seat: String?, for item: SharedBoardItem) async {
        await apply(.seat(seat), to: item) { row in row.seat = seat }
    }

    private func apply(
        _ change: SharedItemChange,
        to item: SharedBoardItem,
        optimistic: (inout SharedBoardItem) -> Void
    ) async {
        guard let repository, let board else { return }
        // AC-SB-08-M / AC-SB-09-M: read リンク・`editable: false` の行・identity_summary は編集させない。
        // **理由（プラン超過 / 非公開名義）はサーバーが区別しないので、こちらも推測して説明しない**
        guard let handle = item.handle, handle.editable, canEdit else {
            itemMessages[item.id] = "この行は編集できません"
            return
        }
        guard let token = openedToken, !savingItemIDs.contains(item.id) else { return }
        guard let index = self.board?.items.firstIndex(where: { $0.id == item.id }) else { return }

        let original = self.board?.items[index]
        savingItemIDs.insert(item.id)
        itemMessages[item.id] = nil
        // 楽観更新（失敗したら元に戻す）
        if var row = self.board?.items[index] {
            optimistic(&row)
            self.board?.items[index] = row
        }
        defer { savingItemIDs.remove(item.id) }

        do {
            let updated = try await repository.updateItem(
                token: token,
                itemKey: handle.itemKey,
                rev: handle.rev,
                change: change
            )
            replace(itemID: item.id, with: updated)
        } catch {
            await handleUpdateFailure(
                Self.appError(from: error),
                itemID: item.id,
                original: original,
                token: token
            )
        }
    }

    private func handleUpdateFailure(
        _ appError: AppError,
        itemID: String,
        original: SharedBoardItem?,
        token: String
    ) async {
        // 失敗したら楽観更新を巻き戻す（`.shareItemConflict` はこの後 current で上書きする）
        if let original { replace(itemID: itemID, with: original) }

        switch appError {
        case .shareItemConflict(let current):
            // **その行だけ**最新値と新しい `rev` で描き直す。ボード全体を再取得しない（AC-SB-10-M）
            redraw(itemID: itemID, with: current)
            itemMessages[itemID] = "他の人が先に更新しました。最新の内容に更新しました"
        case .forbidden:
            itemMessages[itemID] = "この行は編集できません"
        case .shareInvalid:
            // token 失効か `item_key` 不一致かは**レスポンスから区別できない**（同じ 404）。
            // ボードを取り直して判定する: 取れれば表が変わっただけ、取れなければ共有そのものが終了
            await load(token: token)
            if !isEnded {
                actionError = .notFound
            }
        case .rateLimited:
            // **自動リトライしない**（E-17）
            actionError = .rateLimited
        default:
            itemMessages[itemID] = appError.userMessage
        }
    }

    private func replace(itemID: String, with item: SharedBoardItem) {
        guard let index = board?.items.firstIndex(where: { $0.id == itemID }),
              let current = board?.items[index] else { return }
        var row = item
        // 並び順は GET のレスポンス由来。PATCH の 1 件レスポンスからは分からないので元の行の値を保つ
        row.rowIndex = current.rowIndex
        board?.items[index] = row
    }

    /// `CONFLICT` 409 の `details.current` でその行だけ描き直す。
    /// `item_key` は変わらないので `handle` の `itemKey` / `editable` は保ち、`rev` だけ差し替える。
    private func redraw(itemID: String, with current: SharedItemSnapshot) {
        guard let index = board?.items.firstIndex(where: { $0.id == itemID }),
              var row = board?.items[index] else { return }
        row.status = current.status
        row.seat = current.seat
        if let handle = row.handle {
            row.handle = SharedItemHandle(
                itemKey: handle.itemKey,
                rev: current.rev,
                editable: handle.editable
            )
        }
        board?.items[index] = row
    }

    private func discardToken(_ token: String) async {
        await tokenStore?.remove(token: token)
        logger.event("shared_board_token_discarded")
    }

    static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "UNEXPECTED", message: nil)
    }
}
