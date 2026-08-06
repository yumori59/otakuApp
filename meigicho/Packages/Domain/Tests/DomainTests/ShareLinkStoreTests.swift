import XCTest
@testable import Domain

/// T4（共有リンク管理・オーナー側）の `plan.md` §4.5。
/// DTO のエンコード（AC-SH-01 / 03 / 04）は `NetworkTests/ShareDTOTests` 側にある（型が Network にあるため）。
@MainActor
final class ShareLinkStoreTests: XCTestCase {
    private let tourA = UUID(uuidString: "00000000-0000-7000-8000-000000000A01")!
    private let tourB = UUID(uuidString: "00000000-0000-7000-8000-000000000B01")!
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    // MARK: - AC-SH-02-T: 共有相手 ID の検証（送信前に弾く）

    func testAccountIDValidatorAcceptsOnlyUppercaseHexFormat() {
        XCTAssertTrue(AccountIDValidator.isValid("ACC-3F9A21"))
        XCTAssertTrue(AccountIDValidator.isValid("ACC-000000"))
        for invalid in ["ACC-3f9a21", "ABC-3F9A21", "ACC-3F9A2", "ACC-3F9A210", "ACC3F9A21", "", "ACC-3F9A2G"] {
            XCTAssertFalse(AccountIDValidator.isValid(invalid), "\(invalid) should be rejected")
        }
    }

    func testValidateReportsInvalidFormatIDs() {
        let result = AccountIDValidator.validate(["ACC-3F9A21", "ABC-123", "acc-aaaaaa"])
        XCTAssertEqual(result, .invalidFormat(["ABC-123", "acc-aaaaaa"]))
    }

    func testValidateRejectsMoreThanTwentyRecipients() {
        let ids = (0..<21).map { String(format: "ACC-%06X", $0) }
        XCTAssertEqual(AccountIDValidator.validate(ids), .tooMany(21))
        XCTAssertEqual(AccountIDValidator.validate(Array(ids.prefix(20))), .valid(Array(ids.prefix(20))))
    }

    func testValidateFromRawTextSplitsOnCommasAndSpaces() {
        XCTAssertEqual(
            AccountIDValidator.validate(raw: "ACC-3F9A21, ACC-000001\nACC-000002"),
            .valid(["ACC-3F9A21", "ACC-000001", "ACC-000002"])
        )
    }

    /// 不正な ID は **repository を呼ぶ前に** 弾く（400 を往復させない）。
    func testCreateRejectsInvalidRecipientsWithoutCallingRepository() async {
        let repository = FakeShareRepository()
        let store = ShareLinkStore(repository: repository, now: { [now] in now })

        let issued = await store.createTourLink(tourID: tourA, permission: .read, recipientIDs: ["ABC-123"])

        XCTAssertNil(issued)
        let created = await repository.createCalls
        XCTAssertTrue(created.isEmpty)
        guard case .validation = store.actionError else {
            return XCTFail("expected .validation but was \(String(describing: store.actionError))")
        }
    }

    // MARK: - AC-SH-04-T: permission は enum でしか選べない

    func testTourSelectionCarriesChosenPermissionAndIdentitySummaryCarriesNone() {
        XCTAssertEqual(ShareScopeSelection.tour(tourA, permission: .read).permission, .read)
        XCTAssertEqual(ShareScopeSelection.tour(tourA, permission: .write).permission, .write)
        // identity_summary は scope_id も permission も持たない（送ると 400）
        XCTAssertNil(ShareScopeSelection.identitySummary.permission)
        XCTAssertNil(ShareScopeSelection.identitySummary.scopeID)
        XCTAssertEqual(ShareScopeSelection.identitySummary.scopeType, .identitySummary)
    }

    func testCreateTourLinkPassesSelectionThrough() async {
        let repository = FakeShareRepository()
        let store = ShareLinkStore(repository: repository, now: { [now] in now })

        let issued = await store.createTourLink(
            tourID: tourA,
            permission: .write,
            recipientIDs: ["ACC-3F9A21"]
        )

        XCTAssertEqual(issued?.token, "tok-1")
        let calls = await repository.createCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].selection, .tour(tourA, permission: .write))
        XCTAssertEqual(calls[0].recipients, ["ACC-3F9A21"])
        XCTAssertTrue(calls[0].maskMemberNo)
        // token / url は発行直後だけ手元に残る（再取得できない）
        XCTAssertEqual(store.lastIssued?.url, "https://example.invalid/s/tok-1")
        store.clearIssued()
        XCTAssertNil(store.lastIssued)
    }

    func testCreateIdentitySummaryLinkDoesNotCarryPermission() async {
        let repository = FakeShareRepository()
        let store = ShareLinkStore(repository: repository, now: { [now] in now })

        _ = await store.createIdentitySummaryLink()

        let calls = await repository.createCalls
        XCTAssertEqual(calls[0].selection, .identitySummary)
    }

    // MARK: - AC-SH-05-T: PLAN_LIMIT_SHARE_WRITE をそのまま文言化する

    func testPlanLimitShareWriteIsSurfacedWithDetails() async {
        let repository = FakeShareRepository(
            createError: .planLimitShareWrite(limit: 3, current: 8)
        )
        let store = ShareLinkStore(repository: repository, now: { [now] in now })

        let issued = await store.createTourLink(tourID: tourA, permission: .write)

        XCTAssertNil(issued)
        XCTAssertEqual(store.actionError, .planLimitShareWrite(limit: 3, current: 8))
        XCTAssertEqual(store.actionError?.userMessage, "編集を許可する共有は 3 公演までです（このツアーは 8 公演）")
    }

    func testPlanLimitShareWriteWithoutDetailsDoesNotCrash() async {
        let repository = FakeShareRepository(createError: .planLimitShareWrite(limit: nil, current: nil))
        let store = ShareLinkStore(repository: repository, now: { [now] in now })

        _ = await store.createTourLink(tourID: tourA, permission: .write)

        XCTAssertEqual(store.actionError, .planLimitShareWrite(limit: nil, current: nil))
        XCTAssertFalse(store.actionError!.userMessage.isEmpty)
    }

    /// 本数上限（`PLAN_LIMIT_SHARE`）は「2 本目」で出る（AC-SH-09-M の文言）。
    func testPlanLimitShareMessage() {
        XCTAssertEqual(
            AppError.planLimitShare(limit: 1, current: 1).userMessage,
            "無料プランで作れる共有リンクは 1 本までです"
        )
    }

    // MARK: - 3 状態（未共有 / 共有中 / 共有終了）

    func testShareStateIsUnsharedWhenNoLinkExists() {
        let store = ShareLinkStore(repository: FakeShareRepository(), now: { [now] in now })
        XCTAssertEqual(store.shareState(forTour: tourA), .unshared)
    }

    func testShareStatePicksActiveLinkForTheMatchingScopeOnly() async {
        let active = link(id: 1, scopeID: tourA, isActive: true, createdAt: now)
        let other = link(id: 2, scopeID: tourB, isActive: true, createdAt: now)
        let store = await loadedStore(links: [active, other])

        XCTAssertEqual(store.shareState(forTour: tourA), .shared(active))
        XCTAssertEqual(store.shareState(forTour: tourB), .shared(other))
    }

    func testShareStateIsEndedWhenAllLinksAreRevoked() async {
        let revoked = link(id: 1, scopeID: tourA, isActive: false, revokedAt: now, createdAt: now)
        let store = await loadedStore(links: [revoked])
        XCTAssertEqual(store.shareState(forTour: tourA), .ended(revoked))
    }

    /// E-11: 取得後に期限が過ぎた場合、`is_active` が true のままでも終了として扱う。
    func testExpiredLinkIsTreatedAsEndedEvenIfServerSaidActive() async {
        let expired = link(
            id: 1,
            scopeID: tourA,
            isActive: true,
            expiresAt: now.addingTimeInterval(-1),
            createdAt: now.addingTimeInterval(-1000)
        )
        let store = await loadedStore(links: [expired])
        XCTAssertEqual(store.shareState(forTour: tourA), .ended(expired))
    }

    func testNewestActiveLinkWins() async {
        let older = link(id: 1, scopeID: tourA, isActive: true, createdAt: now.addingTimeInterval(-100))
        let newer = link(id: 2, scopeID: tourA, isActive: true, createdAt: now)
        let store = await loadedStore(links: [older, newer])
        XCTAssertEqual(store.shareState(forTour: tourA), .shared(newer))
    }

    func testIdentitySummaryStateIgnoresTourLinks() async {
        let tourLink = link(id: 1, scopeID: tourA, isActive: true, createdAt: now)
        let summary = link(id: 2, scope: .identitySummary, scopeID: nil, isActive: true, createdAt: now)
        let store = await loadedStore(links: [tourLink, summary])

        XCTAssertEqual(store.identitySummaryState, .shared(summary))
        XCTAssertEqual(store.shareState(forTour: tourA), .shared(tourLink))
    }

    // MARK: - 失効

    func testRevokeMovesLinkToEndedWithoutRefetching() async {
        let active = link(id: 1, scopeID: tourA, isActive: true, createdAt: now)
        let repository = FakeShareRepository(links: [active])
        let store = ShareLinkStore(repository: repository, now: { [now] in now })
        await store.load()

        await store.revoke(active.id)

        XCTAssertFalse(store.shareState(forTour: tourA).isShared)
        XCTAssertEqual(store.shareState(forTour: tourA).link?.revokedAt, now)
        let revoked = await repository.revokeCalls
        XCTAssertEqual(revoked, [active.id])
        // list は 1 回（load 時）だけ。失効のたびに取り直さない
        let listCount = await repository.listCallCount
        XCTAssertEqual(listCount, 1)
    }

    func testLoadFailureKeepsAlreadyLoadedLinks() async {
        let active = link(id: 1, scopeID: tourA, isActive: true, createdAt: now)
        let repository = FakeShareRepository(links: [active])
        let store = ShareLinkStore(repository: repository, now: { [now] in now })
        await store.load()

        await repository.setListError(.offline)
        await store.load()

        XCTAssertEqual(store.links.count, 1)
        XCTAssertEqual(store.state, .failed(.offline))
    }

    func testClearRemovesEverything() async {
        let store = await loadedStore(links: [link(id: 1, scopeID: tourA, isActive: true, createdAt: now)])
        store.clear()
        XCTAssertTrue(store.links.isEmpty)
        XCTAssertEqual(store.state, .idle)
        XCTAssertNil(store.lastIssued)
    }

    // MARK: - 表示

    func testAccessCountsSummaryShowsBothViewAndEditCounts() {
        var sample = link(id: 1, scopeID: tourA, isActive: true, createdAt: now)
        sample.viewCount = 3
        sample.editCount = 2
        XCTAssertEqual(sample.accessCountsSummary, "閲覧 3 回 ・ 編集 2 回")
    }

    // MARK: - helpers

    private func loadedStore(links: [ShareLink]) async -> ShareLinkStore {
        let store = ShareLinkStore(repository: FakeShareRepository(links: links), now: { [now] in now })
        await store.load()
        return store
    }

    private func link(
        id: Int,
        scope: ShareScope = .tour,
        scopeID: UUID?,
        isActive: Bool,
        revokedAt: Date? = nil,
        expiresAt: Date? = nil,
        createdAt: Date
    ) -> ShareLink {
        ShareLink(
            id: UUID(uuidString: String(format: "00000000-0000-7000-8000-%012X", id))!,
            scopeType: scope,
            scopeID: scopeID,
            scopeName: nil,
            permission: .read,
            maskMemberNo: true,
            sharedWithAccountIDs: [],
            expiresAt: expiresAt,
            revokedAt: revokedAt,
            createdAt: createdAt,
            isActive: isActive
        )
    }
}

// MARK: - フェイク

private actor FakeShareRepository: ShareRepository {
    struct CreateCall: Equatable {
        let selection: ShareScopeSelection
        let maskMemberNo: Bool
        let recipients: [String]
    }

    private(set) var createCalls: [CreateCall] = []
    private(set) var revokeCalls: [UUID] = []
    private(set) var listCallCount = 0

    private var links: [ShareLink]
    private var createError: AppError?
    private var listError: AppError?

    init(links: [ShareLink] = [], createError: AppError? = nil) {
        self.links = links
        self.createError = createError
    }

    func setListError(_ error: AppError?) {
        listError = error
    }

    func list() async throws -> [ShareLink] {
        listCallCount += 1
        if let listError { throw listError }
        return links
    }

    func create(
        _ selection: ShareScopeSelection,
        maskMemberNo: Bool,
        sharedWithAccountIDs: [String]
    ) async throws -> IssuedShareLink {
        createCalls.append(
            CreateCall(selection: selection, maskMemberNo: maskMemberNo, recipients: sharedWithAccountIDs)
        )
        if let createError { throw createError }
        let token = "tok-\(createCalls.count)"
        let link = ShareLink(
            id: UUID(),
            scopeType: selection.scopeType,
            scopeID: selection.scopeID,
            permission: selection.permission ?? .read,
            maskMemberNo: maskMemberNo,
            sharedWithAccountIDs: sharedWithAccountIDs,
            createdAt: Date(),
            isActive: true
        )
        links.append(link)
        return IssuedShareLink(link: link, token: token, url: "https://example.invalid/s/\(token)")
    }

    func revoke(id: UUID) async throws {
        revokeCalls.append(id)
    }
}
