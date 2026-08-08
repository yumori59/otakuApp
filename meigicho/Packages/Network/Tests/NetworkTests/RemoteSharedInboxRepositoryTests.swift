import XCTest
import Domain
@testable import Network

/// `RemoteSharedInboxRepository` の縦串。`api-contract-delta.md` §4.1 / §4.4 / §4.5。
final class RemoteSharedInboxRepositoryTests: XCTestCase {
    private var recorder: StubRecorder!
    private var repository: RemoteSharedInboxRepository!

    private let shareID = UUID(uuidString: "018f3c2a-1111-7c90-9d2a-000000000001")!

    override func setUp() async throws {
        try await super.setUp()
        recorder = StubRecorder()
        StubURLProtocol.recorder = recorder
        let client = ApiClient(
            configuration: ApiConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            tokenStore: InMemoryTokenStore(token: "refresh-1"),
            session: StubURLProtocol.makeSession()
        )
        await client.adoptSession(
            TokenPair(accessToken: "at-1", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3600))
        )
        repository = RemoteSharedInboxRepository(client: client)
    }

    override func tearDown() async throws {
        StubURLProtocol.recorder = nil
        recorder = nil
        repository = nil
        try await super.tearDown()
    }

    // MARK: - list

    func testListDecodesItemsAndOmitsForbiddenFields() async throws {
        recorder.respond { _ in
            StubResponse(status: 200, body: Data("""
            { "items": [
              { "share_id": "018f3c2a-1111-7c90-9d2a-000000000001",
                "scope_type": "tour", "scope_name": "STELLARIS LIVE TOUR 2026",
                "permission": "write",
                "owner": { "account_id": "ACC-7C1D02", "display_name": "みお" },
                "invited_at": "2026-08-07T00:00:00.000Z",
                "expires_at": "2026-08-31T00:00:00.000Z", "unread": true }
            ] }
            """.utf8))
        }

        let items = try await repository.list()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].shareID, shareID)
        XCTAssertEqual(items[0].scopeName, "STELLARIS LIVE TOUR 2026")
        XCTAssertEqual(items[0].permission, .write)
        XCTAssertEqual(items[0].owner.accountID, "ACC-7C1D02")
        XCTAssertTrue(items[0].unread)
        XCTAssertEqual(recorder.count(path: "/v1/shares/received"), 1)
    }

    /// `scope_name` / `owner.account_id` はサーバー側の型が `string | null`
    /// （`received-share.presenter.ts`）。1 件でも null があると一覧全体のデコードが
    /// 落ちるのを防ぐ（IOS-2）。
    func testListAcceptsNullScopeNameAndNullOwnerAccountID() async throws {
        recorder.respond { _ in
            StubResponse(status: 200, body: Data("""
            { "items": [
              { "share_id": "018f3c2a-1111-7c90-9d2a-000000000001",
                "scope_type": "tour", "scope_name": null,
                "permission": "read",
                "owner": { "account_id": null, "display_name": null },
                "invited_at": "2026-08-07T00:00:00.000Z",
                "expires_at": null, "unread": false }
            ] }
            """.utf8))
        }

        let items = try await repository.list()

        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].scopeName)
        XCTAssertEqual(items[0].displayTitle, "共有された表")
        XCTAssertEqual(items[0].owner.displayLabel, "共有した人")
    }

    func testListEmptyIsNotAnError() async throws {
        recorder.respond { _ in StubResponse(status: 200, body: Data(#"{"items":[]}"#.utf8)) }
        let items = try await repository.list()
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - redeem

    func testRedeemSendsTokenAndReturnsShareID() async throws {
        recorder.respond { _ in
            StubResponse(status: 200, body: Data(#"{"share_id":"018f3c2a-1111-7c90-9d2a-000000000001"}"#.utf8))
        }

        let result = try await repository.redeem(token: "opaque-token")

        XCTAssertEqual(result, shareID)
        XCTAssertEqual(recorder.count(path: "/v1/shares/received/redeem"), 1)
    }

    /// 招待されていない有効トークンは 403 `SHARE_NOT_INVITED` → `.shareNotInvited`。
    /// 汎用マッパーがすでに写すので `RemoteSharedInboxRepository` に特別な処理は無い。
    func testRedeemNotInvitedMapsToShareNotInvited() async {
        recorder.respond { _ in StubResponse(status: 403, body: StubResponse.envelope("SHARE_NOT_INVITED")) }

        do {
            _ = try await repository.redeem(token: "opaque-token")
            XCTFail("403 は throw されるべき")
        } catch {
            XCTAssertEqual(error as? AppError, .shareNotInvited)
        }
    }

    /// 未知 / 失効 / 期限切れは 3 者を区別せず 404 `SHARE_INVALID`。
    func testRedeemInvalidTokenMapsToShareInvalid() async {
        recorder.respond { _ in StubResponse(status: 404, body: StubResponse.envelope("SHARE_INVALID")) }

        do {
            _ = try await repository.redeem(token: "opaque-token")
            XCTFail("404 は throw されるべき")
        } catch {
            XCTAssertEqual(error as? AppError, .shareInvalid)
        }
    }

    // MARK: - setHidden

    func testSetHiddenTrueSendsPost() async throws {
        recorder.respond { _ in StubResponse(status: 204, body: Data()) }

        try await repository.setHidden(shareID: shareID, hidden: true)

        let path = "/v1/shares/received/\(shareID.uuidString.lowercased())/hide"
        XCTAssertEqual(recorder.count(path: path), 1)
    }

    func testSetHiddenFalseSendsDelete() async throws {
        recorder.respond { _ in StubResponse(status: 204, body: Data()) }

        try await repository.setHidden(shareID: shareID, hidden: false)

        let path = "/v1/shares/received/\(shareID.uuidString.lowercased())/hide"
        XCTAssertEqual(recorder.count(path: path), 1)
    }
}
