import XCTest
import Domain
@testable import Network

/// AC-N-12-T: `/v1` あり / なしを取り違えない
final class EndpointTests: XCTestCase {
    private let baseURL = URL(string: "http://localhost:8080")!

    func testVersionedEndpointGetsV1Prefix() throws {
        let endpoint = Endpoint.versioned(.get, "/identities")
        let request = try endpoint.urlRequest(baseURL: baseURL, extraHeaders: [:])
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8080/v1/identities")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testPublicEndpointHasNoV1Prefix() throws {
        let endpoint = Endpoint.publicPath(.get, "/public/shares/abc123")
        let request = try endpoint.urlRequest(baseURL: baseURL, extraHeaders: [:])
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8080/public/shares/abc123")
        XCTAssertFalse(request.url!.path.contains("/v1"))
    }

    func testQueryItemsAreAppended() throws {
        let endpoint = Endpoint.versioned(.get, "/applications", query: [
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "cursor", value: "abc/def+ghi="),
        ])
        let request = try endpoint.urlRequest(baseURL: baseURL, extraHeaders: [:])
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/v1/applications")
        XCTAssertEqual(components.queryItems?.first { $0.name == "limit" }?.value, "200")
        // cursor は不透明値。エンコードして往復できること
        XCTAssertEqual(components.queryItems?.first { $0.name == "cursor" }?.value, "abc/def+ghi=")
    }

    func testBaseURLWithTrailingSlashDoesNotDoubleUp() throws {
        let endpoint = Endpoint.versioned(.get, "/identities")
        let request = try endpoint.urlRequest(baseURL: URL(string: "http://localhost:8080/")!, extraHeaders: [:])
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:8080/v1/identities")
    }

    func testContentTypeIsOnlySetWhenBodyExists() throws {
        let withoutBody = try Endpoint.versioned(.get, "/me").urlRequest(baseURL: baseURL, extraHeaders: [:])
        XCTAssertNil(withoutBody.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(withoutBody.value(forHTTPHeaderField: "Accept"), "application/json")

        let withBody = try Endpoint.versioned(.post, "/identities", body: Data("{}".utf8))
            .urlRequest(baseURL: baseURL, extraHeaders: [:])
        XCTAssertEqual(withBody.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testRequestIDHeaderIsAStandardUUIDString() throws {
        let request = try Endpoint.versioned(.get, "/me").urlRequest(baseURL: baseURL, extraHeaders: [:])
        let requestID = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Request-Id"))
        XCTAssertNotNil(UUID(uuidString: requestID))
        XCTAssertEqual(requestID, requestID.lowercased())
    }

    func testEndpointNeverBuildsAuthorizationHeaderItself() throws {
        let request = try Endpoint.versioned(.get, "/me").urlRequest(baseURL: baseURL, extraHeaders: [:])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }
}
