import XCTest
import Domain
@testable import Networking

/// 受け取り側・共有ボードの縦串: `RemoteSharedBoardRepository` → `ApiClient` → HTTP。
/// `api-contract-delta.md` §4.2 / §4.3（addressing は `token` ではなく `share_id`。Bearer 必須）。
final class RemoteSharedBoardRepositoryTests: XCTestCase {
    private var recorder: StubRecorder!
    private var repository: RemoteSharedBoardRepository!

    private let shareID = UUID(uuidString: "018f3c2a-1111-7c90-9d2a-000000000001")!
    private let itemKey = "1Gt56wJMBPS98yl60rzPLT"

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
        repository = RemoteSharedBoardRepository(client: client)
    }

    override func tearDown() async throws {
        StubURLProtocol.recorder = nil
        recorder = nil
        repository = nil
        try await super.tearDown()
    }

    private static let boardBody = Data("""
    {
      "scope_type": "tour",
      "permission": "write",
      "tour": { "name": "STELLARIS LIVE TOUR 2026", "artist_name": "STELLARIS" },
      "generated_at": "2026-08-02T10:00:00.000Z",
      "items": [
        { "event_name": "Day1", "venue": null, "event_date": "2026-08-20", "round_name": null,
          "rep_name": "自分", "rep_color": null, "companions": [], "status": "applied", "seat": null,
          "item_key": "1Gt56wJMBPS98yl60rzPLT", "rev": "ez4oUpCAvBRUCH1X", "editable": true }
      ]
    }
    """.utf8)

    // MARK: - addressing（`share_id` / `/v1` / Bearer）

    func testFetchUsesVersionedShareIDPathWithBearer() async throws {
        recorder.respond { _ in StubResponse(status: 200, body: Self.boardBody) }

        let board = try await repository.fetchBoard(shareID: shareID)

        XCTAssertEqual(board.permission, .write)
        XCTAssertEqual(recorder.count(path: "/v1/shares/received/\(shareID.uuidString.lowercased())"), 1)
        XCTAssertEqual(
            recorder.lastAuthorizationHeader(path: "/v1/shares/received/\(shareID.uuidString.lowercased())"),
            .some("Bearer at-1")
        )
    }

    /// 招待されていない / 失効した `share_id` は 404 `SHARE_INVALID`（403 にしない）。
    func testShareInvalidIsMappedAsIs() async {
        recorder.respond { _ in StubResponse(status: 404, body: StubResponse.envelope("SHARE_INVALID")) }

        do {
            _ = try await repository.fetchBoard(shareID: shareID)
            XCTFail("404 は throw されるべき")
        } catch {
            XCTAssertEqual(error as? AppError, .shareInvalid)
        }
    }

    /// 401 は通常の `ApiClient` の refresh 経路に乗る（受け取り側専用のクライアント分離は無くなった）。
    func testUnauthorizedGoesThroughNormalRefreshPath() async {
        recorder.respond { request in
            if request.url?.path == "/v1/auth/refresh" {
                return StubResponse(status: 401, body: StubResponse.envelope("AUTH_REFRESH_INVALID"))
            }
            return StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }

        do {
            _ = try await repository.fetchBoard(shareID: shareID)
            XCTFail("401 は throw されるべき")
        } catch {
            XCTAssertEqual(error as? AppError, .sessionExpired)
        }
        XCTAssertEqual(recorder.count(path: "/v1/auth/refresh"), 1)
    }

    // MARK: - 更新

    func testUpdateSendsPatchWithRevAndReturnsUpdatedItem() async throws {
        let key = itemKey
        recorder.respond { _ in
            StubResponse(status: 200, body: Data("""
            { "event_name": "Day1", "venue": null, "event_date": null, "round_name": null,
              "rep_name": "自分", "rep_color": null, "companions": [], "status": "won",
              "seat": "1F A列 12番", "item_key": "\(key)", "rev": "NEWREV", "editable": true }
            """.utf8))
        }

        let item = try await repository.updateItem(
            shareID: shareID,
            itemKey: itemKey,
            rev: "ez4oUpCAvBRUCH1X",
            change: .statusAndSeat(.won, "1F A列 12番")
        )

        XCTAssertEqual(item.status, .won)
        XCTAssertEqual(item.seat, "1F A列 12番")
        XCTAssertEqual(item.handle?.rev, "NEWREV")
        let path = "/v1/shares/received/\(shareID.uuidString.lowercased())/items/\(itemKey)"
        XCTAssertEqual(recorder.count(path: path), 1)
        XCTAssertEqual(recorder.lastAuthorizationHeader(path: path), .some("Bearer at-1"))
    }

    // MARK: - AC-SB-05-T: 409 が `.shareItemConflict` として呼び出し側まで届く

    func testConflictReachesCallerAsShareItemConflict() async {
        recorder.respond { _ in
            StubResponse(status: 409, body: Data("""
            { "code": "CONFLICT", "message": "share item was updated by someone else",
              "details": { "current": { "status": "lost", "seat": null, "rev": "Y3VycmVudC1yZXY" } },
              "request_id": "req-1" }
            """.utf8))
        }

        do {
            _ = try await repository.updateItem(shareID: shareID, itemKey: itemKey, rev: "OLD", change: .status(.won))
            XCTFail("409 は throw されるべき")
        } catch {
            XCTAssertEqual(
                error as? AppError,
                .shareItemConflict(current: SharedItemSnapshot(status: .lost, seat: nil, rev: "Y3VycmVudC1yZXY"))
            )
        }
        XCTAssertEqual(recorder.total, 1, "**自動リトライしない**")
    }

    /// `details` が読めない 409 は `.conflict` のまま届く。
    func testConflictWithoutDetailsStaysGenericConflict() async {
        recorder.respond { _ in StubResponse(status: 409, body: StubResponse.envelope("CONFLICT")) }

        do {
            _ = try await repository.updateItem(shareID: shareID, itemKey: itemKey, rev: "OLD", change: .status(.won))
            XCTFail("409 は throw されるべき")
        } catch {
            XCTAssertEqual(error as? AppError, .conflict)
        }
    }

    func testForbiddenAndRateLimitedAreMappedAsIs() async {
        let cases: [(String, Int, AppError)] = [
            ("FORBIDDEN", 403, .forbidden),
            ("RATE_LIMITED", 429, .rateLimited),
        ]
        for (code, status, expected) in cases {
            recorder.respond { _ in StubResponse(status: status, body: StubResponse.envelope(code)) }
            do {
                _ = try await repository.updateItem(shareID: shareID, itemKey: itemKey, rev: "R", change: .status(.won))
                XCTFail("\(code) は throw されるべき")
            } catch {
                XCTAssertEqual(error as? AppError, expected)
            }
        }
    }
}
