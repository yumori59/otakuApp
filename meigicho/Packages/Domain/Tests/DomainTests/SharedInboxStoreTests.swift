import XCTest
@testable import Domain

/// 受信箱（`api-contract-delta.md` §4.1 / §4.4 / §4.5）。
@MainActor
final class SharedInboxStoreTests: XCTestCase {

    // MARK: - 読み込み

    func testLoadPopulatesItemsAndUnreadCount() async {
        let store = SharedInboxStore(repository: StubSharedInboxRepository(items: [unread(), read()]))

        await store.load()

        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.state, .loaded)
    }

    /// 招待 0 件は「空」であってエラーではない（AC-SI-46）。
    func testEmptyInboxIsLoadedNotFailed() async {
        let store = SharedInboxStore(repository: StubSharedInboxRepository(items: []))

        await store.load()

        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.state, .loaded)
        XCTAssertNil(store.state.error)
    }

    /// E-1: 取り直しに失敗しても表示中の一覧を消さない。
    func testReloadFailureKeepsExistingItems() async {
        let repository = StubSharedInboxRepository(items: [unread()])
        let store = SharedInboxStore(repository: repository)
        await store.load()

        repository.listResult = .failure(.offline)
        await store.load()

        XCTAssertEqual(store.items.count, 1, "既存の表示を消さない")
        XCTAssertEqual(store.state.error, .offline)
    }

    // MARK: - 非表示

    func testHideRemovesRowOptimistically() async {
        let repository = StubSharedInboxRepository(items: [unread()])
        let store = SharedInboxStore(repository: repository)
        await store.load()

        await store.setHidden(shareID: Self.shareID, hidden: true)

        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(repository.hideCalls.map(\.hidden), [true])
        XCTAssertNil(store.actionError)
    }

    /// 失敗したら消した行を戻す（消えたままだと二度と操作できない）。
    func testHideFailureRestoresRow() async {
        let repository = StubSharedInboxRepository(items: [unread()])
        let store = SharedInboxStore(repository: repository)
        await store.load()
        repository.hideResult = .failure(.rateLimited)

        await store.setHidden(shareID: Self.shareID, hidden: true)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.actionError, .rateLimited)
    }

    // MARK: - 未読

    func testMarkReadClearsUnreadLocallyWithoutRoundTrip() async {
        let repository = StubSharedInboxRepository(items: [unread()])
        let store = SharedInboxStore(repository: repository)
        await store.load()

        store.markRead(shareID: Self.shareID)

        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertEqual(repository.listCallCount, 1, "サーバーに問い合わせ直さない")
    }

    // MARK: - redeem

    func testRedeemReturnsShareID() async {
        let store = SharedInboxStore(repository: StubSharedInboxRepository(items: []))

        let resolved = await store.redeem(token: "TOK")

        XCTAssertEqual(resolved, Self.shareID)
        XCTAssertNil(store.actionError)
    }

    /// `SHARE_NOT_INVITED` は redeem 専用の 403。文言で理由が分かるようにする（F2）。
    func testRedeemNotInvitedSurfacesDedicatedMessage() async {
        let repository = StubSharedInboxRepository(items: [])
        repository.redeemResult = .failure(.shareNotInvited)
        let store = SharedInboxStore(repository: repository)

        let resolved = await store.redeem(token: "TOK")

        XCTAssertNil(resolved)
        XCTAssertEqual(store.actionError, .shareNotInvited)
        XCTAssertEqual(store.actionError?.userMessage, "この共有はあなたに共有されていません")
    }

    // MARK: - fixtures

    static let shareID = UUID(uuidString: "018f3c2a-1111-7c90-9d2a-000000000001")!
    static let otherShareID = UUID(uuidString: "018f3c2a-1111-7c90-9d2a-000000000002")!

    private func unread() -> SharedInboxItem {
        SharedInboxItem(
            shareID: Self.shareID,
            scopeType: .tour,
            scopeName: "STELLARIS LIVE TOUR 2026",
            permission: .write,
            owner: SharedInboxOwner(accountID: "ACC-7C1D02", displayName: "みお"),
            invitedAt: Date(timeIntervalSince1970: 1_785_000_000),
            unread: true
        )
    }

    private func read() -> SharedInboxItem {
        SharedInboxItem(
            shareID: Self.otherShareID,
            scopeType: .identitySummary,
            scopeName: "名義の申込サマリー",
            permission: .read,
            owner: SharedInboxOwner(accountID: "ACC-000001", displayName: nil),
            invitedAt: Date(timeIntervalSince1970: 1_784_000_000),
            unread: false
        )
    }
}

// MARK: - Stub

@MainActor
private final class StubSharedInboxRepository: SharedInboxRepository, @unchecked Sendable {
    struct HideCall: Equatable {
        let shareID: UUID
        let hidden: Bool
    }

    var listResult: Result<[SharedInboxItem], AppError>
    var redeemResult: Result<UUID, AppError> = .success(SharedInboxStoreTests.shareID)
    var hideResult: Result<Void, AppError> = .success(())
    private(set) var listCallCount = 0
    private(set) var hideCalls: [HideCall] = []

    init(items: [SharedInboxItem]) {
        listResult = .success(items)
    }

    nonisolated func list() async throws -> [SharedInboxItem] {
        try await MainActor.run {
            listCallCount += 1
            return try listResult.get()
        }
    }

    nonisolated func redeem(token: String) async throws -> UUID {
        try await MainActor.run { try redeemResult.get() }
    }

    nonisolated func setHidden(shareID: UUID, hidden: Bool) async throws {
        try await MainActor.run {
            hideCalls.append(HideCall(shareID: shareID, hidden: hidden))
            return try hideResult.get()
        }
    }
}
