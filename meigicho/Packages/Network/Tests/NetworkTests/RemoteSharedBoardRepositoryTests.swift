import XCTest
import Domain
@testable import Network

/// T4b の縦串: `RemoteSharedBoardRepository` → `PublicApiClient` → HTTP。
///
/// **最重要**: この経路が `Authorization` を送らないこと・401 で再送しないこと（R7 / AC-SB-13-M）。
/// スタブ（`StubURLProtocol` / `StubRecorder`）は `ApiClientRefreshTests.swift` のものを共有する。
final class RemoteSharedBoardRepositoryTests: XCTestCase {
    private var recorder: StubRecorder!
    private var repository: RemoteSharedBoardRepository!

    private let token = "ZQw6TFTbgQZGmqQcUvFIcBC6vQ88OZHljkXNXZg-hWg"
    private let itemKey = "1Gt56wJMBPS98yl60rzPLT"

    override func setUp() async throws {
        try await super.setUp()
        recorder = StubRecorder()
        StubURLProtocol.recorder = recorder
        repository = RemoteSharedBoardRepository(
            client: PublicApiClient(
                configuration: ApiConfiguration(baseURL: URL(string: "http://localhost:8080")!),
                session: StubURLProtocol.makeSession()
            )
        )
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

    // MARK: - AC-SB-13-M の機械化: Bearer を送らない / 401 で再送しない

    func testFetchSendsNoAuthorizationHeaderAndUsesUnversionedPath() async throws {
        recorder.respond { _ in StubResponse(status: 200, body: Self.boardBody) }

        let board = try await repository.fetchBoard(token: token)

        XCTAssertEqual(board.permission, .write)
        XCTAssertEqual(recorder.count(path: "/public/shares/\(token)"), 1)
        // **`/v1` が付かない**
        XCTAssertEqual(recorder.count(path: "/v1/public/shares/\(token)"), 0)
        // **`Authorization` を組み立てない**
        XCTAssertEqual(recorder.lastAuthorizationHeader(path: "/public/shares/\(token)"), .some(nil))
    }

    /// 公開経路で 401 が返っても **refresh も再送もしない**。
    /// ここが壊れると、ボードを開いただけのユーザーが自分のアカウントからログアウトさせられる。
    func testUnauthorizedIsNotRetriedAndDoesNotTouchRefresh() async {
        recorder.respond { _ in StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED")) }

        do {
            _ = try await repository.fetchBoard(token: token)
            XCTFail("401 は throw されるべき")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthenticated)
        }
        XCTAssertEqual(recorder.total, 1, "再送しない")
        XCTAssertEqual(recorder.count(path: "/v1/auth/refresh"), 0, "refresh を叩かない")
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
            token: token,
            itemKey: itemKey,
            rev: "ez4oUpCAvBRUCH1X",
            change: .statusAndSeat(.won, "1F A列 12番")
        )

        XCTAssertEqual(item.status, .won)
        XCTAssertEqual(item.seat, "1F A列 12番")
        XCTAssertEqual(item.handle?.rev, "NEWREV")
        XCTAssertEqual(recorder.count(path: "/public/shares/\(token)/items/\(itemKey)"), 1)
        XCTAssertEqual(
            recorder.lastAuthorizationHeader(path: "/public/shares/\(token)/items/\(itemKey)"),
            .some(nil)
        )
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
            _ = try await repository.updateItem(token: token, itemKey: itemKey, rev: "OLD", change: .status(.won))
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
            _ = try await repository.updateItem(token: token, itemKey: itemKey, rev: "OLD", change: .status(.won))
            XCTFail("409 は throw されるべき")
        } catch {
            XCTAssertEqual(error as? AppError, .conflict)
        }
    }

    func testShareInvalidAndForbiddenAndRateLimitedAreMappedAsIs() async {
        let cases: [(String, Int, AppError)] = [
            ("SHARE_INVALID", 404, .shareInvalid),
            ("FORBIDDEN", 403, .forbidden),
            ("RATE_LIMITED", 429, .rateLimited),
        ]
        for (code, status, expected) in cases {
            recorder.respond { _ in StubResponse(status: status, body: StubResponse.envelope(code)) }
            do {
                _ = try await repository.updateItem(token: token, itemKey: itemKey, rev: "R", change: .status(.won))
                XCTFail("\(code) は throw されるべき")
            } catch {
                XCTAssertEqual(error as? AppError, expected)
            }
        }
    }
}
