import XCTest
import Domain
@testable import Network

/// `Remote{Application,Catalog}Repository` のパス・クエリ・メソッドの配線確認。
/// **`POST /v1/tours` / `POST /v1/events` を呼ばない**ことも含む（C3）。
final class RemoteApplicationRepositoryTests: XCTestCase {
    private var recorder: StubRecorder!
    private var client: ApiClient!
    /// 送信された `URLRequest` を残す箱（`StubRecorder` は URL を持たないため）
    private var sent: SentRequests!

    override func setUp() async throws {
        try await super.setUp()
        recorder = StubRecorder()
        sent = SentRequests()
        StubURLProtocol.recorder = recorder
        client = ApiClient(
            configuration: ApiConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            tokenStore: InMemoryTokenStore(token: "refresh-1"),
            session: StubURLProtocol.makeSession()
        )
        await client.adoptSession(
            TokenPair(accessToken: "at-1", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3600))
        )
    }

    override func tearDown() async throws {
        StubURLProtocol.recorder = nil
        recorder = nil
        sent = nil
        client = nil
        try await super.tearDown()
    }

    func testListPagePassesCursorThroughUnmodified() async throws {
        let cursor = "2026-07-31T12:05:00.000Z|018f3c2a-cccc-7c90-9d2a-000000000001"
        recorder.respond { [sent] request in
            sent?.append(request)
            return StubResponse(status: 200, body: Data(#"{"items":[],"next_cursor":null,"has_more":false}"#.utf8))
        }
        let repository = RemoteApplicationRepository(client: client)
        let page = try await repository.listPage(limit: 200, cursor: cursor)

        XCTAssertTrue(page.items.isEmpty)
        XCTAssertFalse(page.hasMore)
        let url = try XCTUnwrap(sent.lastURL(path: "/v1/applications"))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "200")
        XCTAssertEqual(query.first { $0.name == "cursor" }?.value, cursor)
    }

    func testListPageOmitsCursorOnFirstPage() async throws {
        recorder.respond { [sent] request in
            sent?.append(request)
            return StubResponse(status: 200, body: Data(#"{"items":[],"next_cursor":null,"has_more":false}"#.utf8))
        }
        _ = try await RemoteApplicationRepository(client: client).listPage(limit: 200, cursor: nil)
        let url = try XCTUnwrap(sent.lastURL(path: "/v1/applications"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(query.first { $0.name == "cursor" })
    }

    func testFetchEventUsesSingleEventPath() async throws {
        let id = UUID(uuidString: "018f3c2a-eeee-7c90-9d2a-000000000001")!
        recorder.respond { _ in
            StubResponse(status: 200, body: Data("""
            {"id":"018f3c2a-eeee-7c90-9d2a-000000000001","tour_id":"018f3c2a-dddd-7c90-9d2a-000000000001",
             "name":"大阪公演 Day1","venue_name_raw":null,"event_date":"2026-08-20","starts_at":null,
             "created_at":"2026-08-01T00:00:00.000Z","updated_at":"2026-08-01T00:00:00.000Z","deleted_at":null}
            """.utf8))
        }
        let event = try await RemoteCatalogRepository(client: client).fetchEvent(id: id)
        XCTAssertEqual(event.name, "大阪公演 Day1")
        XCTAssertEqual(recorder.count(path: "/v1/events/018f3c2a-eeee-7c90-9d2a-000000000001"), 1)
    }

    func testListToursAndEventsUnwrapItems() async throws {
        recorder.respond { request in
            request.url?.path == "/v1/tours"
                ? StubResponse(status: 200, body: Data("""
                  {"items":[{"id":"018f3c2a-dddd-7c90-9d2a-000000000001","name":"TOUR","artist_name_raw":"A",
                   "created_at":"2026-08-01T00:00:00.000Z","updated_at":"2026-08-01T00:00:00.000Z","deleted_at":null}]}
                  """.utf8))
                : StubResponse(status: 200, body: Data(#"{"items":[]}"#.utf8))
        }
        let repository = RemoteCatalogRepository(client: client)
        let tours = try await repository.listTours()
        let events = try await repository.listEvents()
        XCTAssertEqual(tours.map(\.name), ["TOUR"])
        XCTAssertTrue(events.isEmpty)
    }

    /// エラー envelope はそのまま `AppError` に写る（`CONFLICT` を握りつぶさない = E-2）
    func testConflictIsSurfacedAsAppError() async {
        recorder.respond { _ in StubResponse(status: 409, body: StubResponse.envelope("CONFLICT")) }
        let draft = ApplicationDraft(
            tour: TourDraft(name: "TOUR"),
            event: EventDraft(name: "公演"),
            repIdentityID: UUID()
        )
        do {
            _ = try await RemoteApplicationRepository(client: client).create(draft)
            XCTFail("CONFLICT が伝播していない")
        } catch {
            XCTAssertEqual(error as? AppError, .conflict)
        }
    }
}

/// `URLRequest` を記録する箱。`StubURLProtocol` の応答クロージャから使う。
final class SentRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    func lastURL(path: String) -> URL? {
        lock.withLock { requests.last { $0.url?.path == path }?.url }
    }

    func lastRequest(path: String) -> URLRequest? {
        lock.withLock { requests.last { $0.url?.path == path } }
    }
}
