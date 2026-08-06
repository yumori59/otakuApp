import XCTest
import Domain
@testable import Network

/// `RemoteAuthRepository.deleteAccount` の配線確認（`account-deletion/api-contract-delta.md` §1・§3.2）。
/// AC-AD-04-M・05-M。
final class RemoteAuthRepositoryTests: XCTestCase {
    private var recorder: StubRecorder!
    private var client: ApiClient!
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

    /// AC-AD-05-M: `DELETE /v1/me` を **Bearer 付きで** 叩き、204 を `Void` として受ける
    func testDeleteAccountSendsDeleteToMeWithBearer() async throws {
        recorder.respond { [sent] request in
            sent?.append(request)
            return StubResponse(status: 204, body: Data())
        }
        let repository = RemoteAuthRepository(client: client)
        try await repository.deleteAccount(password: "correct horse", appleAuthorizationCode: "c1a2b3")

        XCTAssertEqual(recorder.count(path: "/v1/me"), 1)
        XCTAssertEqual(recorder.lastAuthorizationHeader(path: "/v1/me"), "Bearer at-1")

        let sentRequest = try XCTUnwrap(sent.lastRequest(path: "/v1/me"))
        XCTAssertEqual(sentRequest.httpMethod, "DELETE")
        let bodyData = try XCTUnwrap(sentRequest.httpBodyOrStream)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(json["password"] as? String, "correct horse")
        XCTAssertEqual(json["apple_authorization_code"] as? String, "c1a2b3")
    }

    /// AC-AD-05-M: `NOT_FOUND` は `.notFound` として伝播する（黙って握りつぶさない）
    func testDeleteAccountNotFoundIsSurfacedAsAppError() async {
        recorder.respond { _ in StubResponse(status: 404, body: StubResponse.envelope("NOT_FOUND")) }
        let repository = RemoteAuthRepository(client: client)
        do {
            try await repository.deleteAccount(password: nil, appleAuthorizationCode: nil)
            XCTFail("NOT_FOUND が伝播していない")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }
}

private extension URLRequest {
    /// `URLRequest.httpBody` は URLSession に渡す前提だと nil になりうるため保険として httpBodyStream も見る。
    var httpBodyOrStream: Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
