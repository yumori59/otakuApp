import Foundation
import Core

// 共有ボード（受け取り側）。**Bearer 必須の経路**（`api-contract-delta.md` §4.2 / §4.3）。
//
// このファイルが知っていること:
// - 共有は**招待されたアカウントだけ**が開ける。受け取り側は必ず自分のアカウントでログインしている
// - addressing は `share_id`。token はディープリンクの入口でしか現れず、
//   `redeem`（§4.4）で `share_id` に交換してから使う
// - `item_key` / `rev` は不透明値。解釈も生成もしない
// - ボードの内容は**ローカル永続化しない**（メモリだけ）
//
// **旧前提の破棄**: かつてこの経路は `/public/shares/:token` で、
// 「受け取った人はログインしていない」「公開経路の 401 で自分のアカウントをログアウトさせない」
// ことを設計の中心に置いていた。Q1=A で公開経路が廃止されたため**その前提はもう無い**。
// 401 → refresh → 失敗 → ログアウトは自分のセッションに対する想定どおりの挙動になる。

// MARK: - 共有リンクの URL から token を取り出す（純粋関数）

/// 共有リンクの入力（カスタムスキーム / URL 貼り付け）から token を取り出す。
///
/// 発行される URL は **`meigicho://share/<token>` だけ**（`api-contract-delta.md` §1）。
/// ただしユーザーが手で貼り付ける経路があるので、旧 https 形式と token 直貼りも受け付ける。
/// **ここは形だけを見る。** 有効か・招待されているかは `redeem`（サーバー）が決める。
///
/// Universal Links はスコープ外（`docs/09-roadmap.md` 1-7 と同時の別計画）。
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

        // 旧 https 形式の貼り付け（`/s/<token>` / `/public/shares/<token>`）。
        // **サーバー側の経路はもう無い**が、古いメッセージから拾った文字列でも
        // token として `redeem` に回せるように最後のパス要素だけ取り出す
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
/// 起点は 2 つ:
/// - `open(shareID:)` — 受信箱の行タップ（`share_id` を既に持っている）
/// - `open(token:)` — ディープリンク / 貼り付け（`redeem` で `share_id` に交換してから開く）
@MainActor
@Observable
public final class SharedBoardStore {
    /// 現在開いているボード。**永続化しない**
    public private(set) var board: SharedBoard?
    public private(set) var state: LoadState = .idle
    /// `SHARE_INVALID` を受けた（未知 / 失効 / 期限切れ / 自分は招待されていない）。
    /// **サーバーは理由を区別しない**ので、こちらも推測して説明しない（NFR-1）
    public private(set) var isEnded = false
    /// `redeem` が `SHARE_NOT_INVITED` を返した。**この 1 経路だけが「招待されていない」と言える**
    public private(set) var isNotInvited = false
    /// ボード全体に出す 1 行メッセージ（レート制限など）
    public var actionError: AppError?
    /// 行ごとのメッセージ（`itemID` → 文言）。**その行にだけ出す**
    public private(set) var itemMessages: [String: String] = [:]
    /// 保存中の行（二重送信を防ぐ）
    public private(set) var savingItemIDs: Set<String> = []
    /// 現在開いている共有の id。`reload` と PATCH の addressing に使う
    public private(set) var openedShareID: UUID?

    private let repository: (any SharedBoardRepository)?
    /// `open(token:)`（ディープリンク）のためだけに使う。受信箱一覧は `SharedInboxStore` の担当
    private let inboxRepository: (any SharedInboxRepository)?
    private let logger = AppLogger(category: "shared-board")

    /// 引数を省略した形は **Preview 専用**（ネットワークに触らない）。
    public init(
        repository: (any SharedBoardRepository)? = nil,
        inboxRepository: (any SharedInboxRepository)? = nil
    ) {
        self.repository = repository
        self.inboxRepository = inboxRepository
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

    /// `share_id` でボードを開く（受信箱からの遷移）。
    public func open(shareID: UUID) async {
        openedShareID = shareID
        resetPresentation()
        state = .loading
        await load(shareID: shareID)
    }

    /// token でボードを開く（`meigicho://share/<token>` / 貼り付け）。
    ///
    /// `redeem` で `share_id` に交換してから `open(shareID:)` と同じ経路に合流する。
    /// **未招待（403）とリンク無効（404）はここでしか区別できない。**
    @discardableResult
    public func open(token: String) async -> UUID? {
        guard let inboxRepository else {
            state = .loaded
            return nil
        }
        openedShareID = nil
        resetPresentation()
        state = .loading
        do {
            let shareID = try await inboxRepository.redeem(token: token)
            openedShareID = shareID
            await load(shareID: shareID)
            return shareID
        } catch {
            switch Self.appError(from: error) {
            case .shareNotInvited:
                logger.event("shared_board_not_invited")
                isNotInvited = true
                state = .loaded
            case .shareInvalid:
                isEnded = true
                state = .loaded
            case let appError:
                state = .failed(appError)
            }
            return nil
        }
    }

    /// いま開いている共有で取り直す（ユーザーの明示操作）。
    public func reload() async {
        guard let openedShareID else { return }
        actionError = nil
        state = .loading
        await load(shareID: openedShareID)
    }

    public func clearActionError() { actionError = nil }

    public func clearMessage(for item: SharedBoardItem) { itemMessages[item.id] = nil }

    /// 画面を閉じるときに呼ぶ。**表データをメモリにも残さない**。
    public func close() {
        board = nil
        state = .idle
        openedShareID = nil
        resetPresentation()
        savingItemIDs = []
    }

    private func resetPresentation() {
        isEnded = false
        isNotInvited = false
        actionError = nil
        itemMessages = [:]
    }

    private func load(shareID: UUID) async {
        guard let repository else {
            state = .loaded
            return
        }
        do {
            board = try await repository.fetchBoard(shareID: shareID)
            state = .loaded
        } catch {
            let appError = Self.appError(from: error)
            if case .shareInvalid = appError {
                // 未知 / 失効 / 期限切れ / 招待から外された。**理由は区別されない**（AC-SI-21）
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
        guard let repository, board != nil else { return }
        // AC-SB-08-M / AC-SB-09-M: read リンク・`editable: false` の行・identity_summary は編集させない。
        // **理由（プラン超過 / 非公開名義）はサーバーが区別しないので、こちらも推測して説明しない**
        guard let handle = item.handle, handle.editable, canEdit else {
            itemMessages[item.id] = "この行は編集できません"
            return
        }
        guard let shareID = openedShareID, !savingItemIDs.contains(item.id) else { return }
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
                shareID: shareID,
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
                shareID: shareID
            )
        }
    }

    private func handleUpdateFailure(
        _ appError: AppError,
        itemID: String,
        original: SharedBoardItem?,
        shareID: UUID
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
            // 共有の失効か `item_key` 不一致かは**レスポンスから区別できない**（同じ 404）。
            // ボードを取り直して判定する: 取れれば表が変わっただけ、取れなければ共有そのものが終了
            await load(shareID: shareID)
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

    static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "UNEXPECTED", message: nil)
    }
}
