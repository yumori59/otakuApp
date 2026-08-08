import XCTest
@testable import Domain

/// T4b（共有ボード・受け取り側）。`plan.md` §4.5b / `contract-mapping.md` §4.8。
///
/// DTO のエンコード / デコードと `CONFLICT` 格上げ（AC-SB-01/03/04/05）は
/// 対象の型が `Network` にあるため `NetworkTests/SharedBoardDTOTests` 側にある。
@MainActor
final class SharedBoardStoreTests: XCTestCase {

    // MARK: - エントリポイント（token の取り出し）

    func testCustomSchemeURLYieldsToken() {
        XCTAssertEqual(SharedBoardLink.token(from: "meigicho://share/abc-123_XYZ"), "abc-123_XYZ")
        XCTAssertEqual(SharedBoardLink.token(from: URL(string: "meigicho://share/tok")!), "tok")
    }

    func testCustomSchemeWithOtherHostIsRejected() {
        // Google OAuth のコールバックなど、共有以外の URL を拾わない
        XCTAssertNil(SharedBoardLink.token(from: "meigicho://oauth/callback"))
        XCTAssertNil(SharedBoardLink.token(from: "meigicho://share"))
        XCTAssertNil(SharedBoardLink.token(from: "com.googleusercontent.apps.123://cb"))
    }

    func testHTTPShareURLUsesLastPathComponent() {
        XCTAssertEqual(SharedBoardLink.token(from: "https://share.example.com/s/TOKEN123"), "TOKEN123")
        XCTAssertEqual(
            SharedBoardLink.token(from: "http://localhost:8080/public/shares/TOKEN123"),
            "TOKEN123"
        )
    }

    func testBareTokenIsAccepted() {
        XCTAssertEqual(SharedBoardLink.token(from: "  b3RhLWtleQ  "), "b3RhLWtleQ")
    }

    func testMalformedInputIsRejected() {
        for raw in ["", "   ", "https://share.example.com/", "not a token", "tok/en", "トークン"] {
            XCTAssertNil(SharedBoardLink.token(from: raw), "\(raw) は token として受けない")
        }
    }

    // MARK: - read リンク / editable: false は編集させない（AC-SB-08-M / 09-M の自動化部分）

    func testReadLinkRowsAreNotEditable() {
        let store = SharedBoardStore()
        XCTAssertFalse(store.isEditable(item(handle: nil)))
    }

    func testWriteLinkRespectsPerRowEditableFlag() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        let rows = try? XCTUnwrap(store.board?.items)
        XCTAssertEqual(store.isEditable(rows![0]), true)
        // `editable: false` の理由（プラン超過 / 非公開名義）は**サーバーが区別しない**ので推測しない
        XCTAssertEqual(store.isEditable(rows![1]), false)
    }

    func testEditingNonEditableRowShowsRowMessageAndDoesNotCallRepository() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        let locked = try! XCTUnwrap(store.board?.items[1])
        await store.setStatus(.won, for: locked)

        XCTAssertEqual(store.message(for: locked), "この行は編集できません")
        XCTAssertEqual(repository.updateCallCount, 0)
        XCTAssertEqual(store.board?.items[1].status, .applied)
    }

    // MARK: - 更新の成功

    func testSuccessfulUpdateReplacesOnlyThatRow() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        repository.updateResult = .success(
            item(key: "K1", rev: "REV-2", status: .won, seat: "1F A列 12番")
        )
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        let target = try! XCTUnwrap(store.board?.items.first)
        await store.setStatus(.won, for: target)

        XCTAssertEqual(store.board?.items[0].status, .won)
        XCTAssertEqual(store.board?.items[0].seat, "1F A列 12番")
        // GET で受け取った rev をそのまま送っている（不透明値を解釈しない）
        XCTAssertEqual(repository.lastRev, "REV-1")
        XCTAssertEqual(repository.lastItemKey, "K1")
        // 他の行は触らない
        XCTAssertEqual(store.board?.items[1].status, .applied)
        XCTAssertEqual(repository.fetchCallCount, 1, "ボード全体を再取得しない")
    }

    /// P5: 空文字は空文字のまま送る（`null` に丸めない）。
    func testEmptySeatIsSentAsEmptyString() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        repository.updateResult = .success(item(key: "K1", rev: "REV-2", status: .applied, seat: ""))
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        await store.saveSeat("", for: try! XCTUnwrap(store.board?.items.first))
        XCTAssertEqual(repository.lastChange, .seat(""))

        await store.saveSeat(nil, for: try! XCTUnwrap(store.board?.items.first))
        XCTAssertEqual(repository.lastChange, .seat(nil))
    }

    // MARK: - AC-SB-10-M: CONFLICT はその行だけ描き直す

    func testConflictRedrawsOnlyThatRowWithoutRefetchingBoard() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        repository.updateResult = .failure(
            .shareItemConflict(current: SharedItemSnapshot(status: .lost, seat: "S9", rev: "REV-9"))
        )
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        await store.setStatus(.won, for: try! XCTUnwrap(store.board?.items.first))

        XCTAssertEqual(store.board?.items[0].status, .lost)
        XCTAssertEqual(store.board?.items[0].seat, "S9")
        // rev だけ差し替え、item_key / editable は保つ
        XCTAssertEqual(store.board?.items[0].handle?.rev, "REV-9")
        XCTAssertEqual(store.board?.items[0].handle?.itemKey, "K1")
        XCTAssertEqual(store.board?.items[0].handle?.editable, true)
        XCTAssertEqual(store.message(for: store.board!.items[0]), "他の人が先に更新しました。最新の内容に更新しました")
        XCTAssertEqual(repository.fetchCallCount, 1, "ボード全体を再取得しない")
        XCTAssertNil(store.actionError)
    }

    // MARK: - FORBIDDEN は行を元に戻す

    func testForbiddenRevertsRowAndShowsRowMessage() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        repository.updateResult = .failure(.forbidden)
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        await store.setStatus(.won, for: try! XCTUnwrap(store.board?.items.first))

        XCTAssertEqual(store.board?.items[0].status, .applied, "楽観更新を巻き戻す")
        // 理由（プラン超過 / 非公開名義）を推測して説明しない
        XCTAssertEqual(store.message(for: store.board!.items[0]), "この行は編集できません")
    }

    // MARK: - SHARE_INVALID は理由を区別せず「終了」に落とす（AC-SI-21）

    /// 未知 / 失効 / 期限切れ / **自分が招待されていない** の 4 つはすべて 404 `SHARE_INVALID`。
    /// クライアントも理由を推測しない（`isNotInvited` は redeem 経路でしか立たない）。
    func testShareInvalidOnFetchEndsBoard() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        repository.fetchResult = .failure(.shareInvalid)
        let store = SharedBoardStore(repository: repository)

        await store.open(shareID: Self.shareID)

        XCTAssertTrue(store.isEnded)
        XCTAssertFalse(store.isNotInvited, "id 経路で「招待されていない」と断定しない")
        XCTAssertNil(store.board)
    }

    /// PATCH の `SHARE_INVALID` は「共有の失効」と「`item_key` 不一致」の両方で返る（同じ 404）。
    /// 取り直せれば表が変わっただけ、取り直せなければ共有そのものが終了。
    func testShareInvalidOnUpdateRefetchesBoardToDisambiguate() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        repository.updateResult = .failure(.shareInvalid)
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        await store.setStatus(.won, for: try! XCTUnwrap(store.board?.items.first))

        XCTAssertEqual(repository.fetchCallCount, 2)
        XCTAssertFalse(store.isEnded, "GET が通るなら共有自体は生きている")
        XCTAssertEqual(store.actionError, .notFound)
    }

    func testShareInvalidOnUpdateEndsBoardWhenRefetchAlsoFails() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        repository.updateResult = .failure(.shareInvalid)
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)
        repository.fetchResult = .failure(.shareInvalid)

        await store.setStatus(.won, for: try! XCTUnwrap(store.board?.items.first))

        XCTAssertTrue(store.isEnded)
    }

    /// PATCH は開いている `share_id` で addressing する（token は現れない）。
    func testUpdateUsesOpenedShareID() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        repository.updateResult = .success(item(key: "K1", rev: "REV-2", status: .won))
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        await store.setStatus(.won, for: try! XCTUnwrap(store.board?.items.first))

        XCTAssertEqual(repository.lastShareID, Self.shareID)
    }

    // MARK: - redeem 起点（ディープリンク）

    func testOpenWithTokenRedeemsThenLoadsBoard() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        let inbox = StubSharedInboxRepository(redeemResult: .success(Self.shareID))
        let store = SharedBoardStore(repository: repository, inboxRepository: inbox)

        let resolved = await store.open(token: "TOK")

        XCTAssertEqual(resolved, Self.shareID)
        XCTAssertEqual(store.openedShareID, Self.shareID)
        XCTAssertEqual(repository.lastShareID, Self.shareID, "redeem で得た shareID で board を取る")
        XCTAssertNotNil(store.board)
        XCTAssertEqual(inbox.lastRedeemedToken, "TOK")
    }

    /// **`SHARE_NOT_INVITED` は redeem でしか返らない**（`api-contract-delta.md` §4.4）。
    /// ここだけが「あなたは招待されていない」と言える。
    func testRedeemNotInvitedShowsDedicatedState() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        let inbox = StubSharedInboxRepository(redeemResult: .failure(.shareNotInvited))
        let store = SharedBoardStore(repository: repository, inboxRepository: inbox)

        let resolved = await store.open(token: "TOK")

        XCTAssertNil(resolved)
        XCTAssertTrue(store.isNotInvited)
        XCTAssertFalse(store.isEnded, "「無効なリンク」とは言わない")
        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(repository.fetchCallCount, 0, "redeem が通らなければ board は取りに行かない")
    }

    func testRedeemShareInvalidEndsBoard() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        let inbox = StubSharedInboxRepository(redeemResult: .failure(.shareInvalid))
        let store = SharedBoardStore(repository: repository, inboxRepository: inbox)

        await store.open(token: "TOK")

        XCTAssertTrue(store.isEnded)
        XCTAssertFalse(store.isNotInvited)
    }

    /// 通信断は「終了」でも「未招待」でもない（再試行できる状態にする）。
    func testRedeemTransportFailureIsRetriableFailure() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        let inbox = StubSharedInboxRepository(redeemResult: .failure(.offline))
        let store = SharedBoardStore(repository: repository, inboxRepository: inbox)

        await store.open(token: "TOK")

        XCTAssertEqual(store.state.error, .offline)
        XCTAssertFalse(store.isEnded)
        XCTAssertFalse(store.isNotInvited)
    }

    // MARK: - AC / E-17: 429 は自動リトライしない

    func testRateLimitedIsSurfacedWithoutRetry() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        repository.updateResult = .failure(.rateLimited)
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        await store.setStatus(.won, for: try! XCTUnwrap(store.board?.items.first))

        XCTAssertEqual(store.actionError, .rateLimited)
        XCTAssertEqual(repository.updateCallCount, 1, "自動リトライしない")
        XCTAssertEqual(store.board?.items[0].status, .applied, "巻き戻す")
    }

    // MARK: - 読み込み失敗は既読データを消さない（E-1）

    func testTransportFailureOnReloadKeepsBoard() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)
        repository.fetchResult = .failure(.offline)

        await store.reload()

        XCTAssertEqual(store.state.error, .offline)
        XCTAssertNotNil(store.board)
        XCTAssertFalse(store.isEnded)
    }

    /// 閉じたらメモリにも残さない（ローカル永続化を持たない方針と揃える）。
    func testCloseClearsEverything() async {
        let repository = StubSharedBoardRepository(board: board(permission: .write))
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        store.close()

        XCTAssertNil(store.board)
        XCTAssertNil(store.openedShareID)
        XCTAssertEqual(store.state, .idle)
    }

    // MARK: - identity_summary スコープ（tour とは別系統の内容）

    func testIdentitySummaryBoardIsNeverEditable() async {
        let repository = StubSharedBoardRepository(board: identitySummaryBoard())
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        XCTAssertEqual(store.board?.scopeType, .identitySummary)
        XCTAssertFalse(store.canEdit)
        XCTAssertTrue(store.board?.items.isEmpty ?? false, "tour の行は 1 件も生えない")
        XCTAssertEqual(store.board?.identitySummaries.count, 2)
        XCTAssertNil(store.board?.identitySummaries[1].counts, "visible:false は件数を出さない")
    }

    /// `permission == .write` を騙って渡されても、identity_summary には編集経路が無い。
    func testIdentitySummaryBoardCannotEditEvenWithWritePermission() async {
        let repository = StubSharedBoardRepository(board: identitySummaryBoard(permission: .write))
        let store = SharedBoardStore(repository: repository)
        await store.open(shareID: Self.shareID)

        XCTAssertFalse(store.canEdit)
        // handle 付きの行を外から差し込んでも repository を呼ばない
        await store.setStatus(.won, for: item(key: "K1", rev: "REV-1", editable: true))
        XCTAssertEqual(repository.updateCallCount, 0)
    }

    /// 画面見出しは tour 名が無くても付く。
    func testIdentitySummaryBoardHasDisplayTitle() async {
        let repository = StubSharedBoardRepository(board: identitySummaryBoard())
        let store = SharedBoardStore(repository: repository)

        await store.open(shareID: Self.shareID)

        XCTAssertNil(store.board?.tourName)
        XCTAssertNotNil(store.board?.displayTitle)
    }

    // MARK: - 行 id の衝突（read リンク）

    /// 同一公演・同一名義でラウンド違いの行が並んでも id が衝突しない。
    /// （`history_visible = false` の名義は `rep_name` が全て同じ文字列にマスクされる）
    func testReadLinkRowIDsAreUniqueForSameEventAndIdentity() {
        let rows = (0..<3).map { index in
            SharedBoardItem(
                rowIndex: index,
                eventName: "大阪公演 Day1",
                eventDate: Date(timeIntervalSince1970: 1_785_000_000),
                roundName: index == 0 ? "FC1次" : "FC2次",
                repName: "非公開の名義",
                status: .applied
            )
        }
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }

    /// write リンクは `item_key` が一意なので、そのまま id に使う（P3 は維持）。
    func testWriteLinkRowIDIsItemKey() {
        let row = SharedBoardItem(
            rowIndex: 7,
            eventName: "E",
            repName: "R",
            status: .applied,
            handle: SharedItemHandle(itemKey: "K9", rev: "R1", editable: true)
        )
        XCTAssertEqual(row.id, "K9")
    }

    // MARK: - fixtures

    /// 共有の addressing キー。**token ではなく share_id**（UUID v7 形）
    static let shareID = UUID(uuidString: "018f3c2a-1111-7c90-9d2a-000000000001")!

    private func identitySummaryBoard(permission: SharePermission = .read) -> SharedBoard {
        SharedBoard(
            permission: permission,
            generatedAt: Date(timeIntervalSince1970: 1_785_000_000),
            identities: [
                SharedIdentitySummaryItem(
                    rowIndex: 0,
                    name: "自分",
                    counts: SharedIdentityCounts(applicationCount: 12, wonCount: 5)
                ),
                SharedIdentitySummaryItem(rowIndex: 1, name: "友人A", counts: nil),
            ]
        )
    }

    private func item(
        rowIndex: Int = 0,
        key: String? = "K1",
        rev: String? = "REV-1",
        editable: Bool? = true,
        status: ApplicationStatus = .applied,
        seat: String? = nil,
        handle: SharedItemHandle? = nil
    ) -> SharedBoardItem {
        SharedBoardItem(
            rowIndex: rowIndex,
            eventName: "大阪公演 Day1",
            venue: "大阪城ホール",
            eventDate: nil,
            roundName: "FC1次",
            repName: "自分",
            repColor: "#0017C1",
            companions: [],
            status: status,
            seat: seat,
            handle: handle ?? SharedItemHandle(itemKey: key, rev: rev, editable: editable)
        )
    }

    private func item(handle: SharedItemHandle?) -> SharedBoardItem {
        SharedBoardItem(rowIndex: 0, eventName: "E", repName: "R", status: .applied, handle: handle)
    }

    private func board(permission: SharePermission) -> SharedBoard {
        SharedBoard(
            permission: permission,
            tourName: "STELLARIS LIVE TOUR 2026",
            artistName: "STELLARIS",
            generatedAt: Date(timeIntervalSince1970: 1_785_000_000),
            items: [
                item(rowIndex: 0, key: "K1", rev: "REV-1", editable: true),
                item(rowIndex: 1, key: "K2", rev: "REV-2", editable: false),
            ]
        )
    }
}

// MARK: - Stubs

@MainActor
private final class StubSharedBoardRepository: SharedBoardRepository, @unchecked Sendable {
    var fetchResult: Result<SharedBoard, AppError>
    var updateResult: Result<SharedBoardItem, AppError>?
    private(set) var fetchCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var lastItemKey: String?
    private(set) var lastRev: String?
    private(set) var lastChange: SharedItemChange?
    private(set) var lastShareID: UUID?

    init(board: SharedBoard) {
        fetchResult = .success(board)
    }

    nonisolated func fetchBoard(shareID: UUID) async throws -> SharedBoard {
        try await MainActor.run {
            fetchCallCount += 1
            lastShareID = shareID
            return try fetchResult.get()
        }
    }

    nonisolated func updateItem(
        shareID: UUID,
        itemKey: String,
        rev: String,
        change: SharedItemChange
    ) async throws -> SharedBoardItem {
        try await MainActor.run {
            updateCallCount += 1
            lastShareID = shareID
            lastItemKey = itemKey
            lastRev = rev
            lastChange = change
            guard let updateResult else {
                throw AppError.unknown(code: "NO_STUB", message: nil)
            }
            return try updateResult.get()
        }
    }
}

@MainActor
private final class StubSharedInboxRepository: SharedInboxRepository, @unchecked Sendable {
    var redeemResult: Result<UUID, AppError>
    private(set) var lastRedeemedToken: String?

    init(redeemResult: Result<UUID, AppError>) {
        self.redeemResult = redeemResult
    }

    nonisolated func list() async throws -> [SharedInboxItem] { [] }

    nonisolated func redeem(token: String) async throws -> UUID {
        try await MainActor.run {
            lastRedeemedToken = token
            return try redeemResult.get()
        }
    }

    nonisolated func setHidden(shareID: UUID, hidden: Bool) async throws {}
}
