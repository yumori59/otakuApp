import XCTest
import Domain
@testable import Networking

/// 401 → refresh → 1 回だけ再送（FR-N-6 / E-5 / E-6）。
/// AC-AUTH-07-M / AC-AUTH-08-M / AC-AUTH-09-M の機械化版。
final class ApiClientRefreshTests: XCTestCase {
    private var recorder: StubRecorder!
    private var client: ApiClient!
    private var tokenStore: InMemoryTokenStore!

    override func setUp() async throws {
        try await super.setUp()
        recorder = StubRecorder()
        StubURLProtocol.recorder = recorder
        tokenStore = InMemoryTokenStore(token: "refresh-1")
        client = ApiClient(
            configuration: ApiConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            tokenStore: tokenStore,
            session: StubURLProtocol.makeSession()
        )
    }

    override func tearDown() async throws {
        StubURLProtocol.recorder = nil
        recorder = nil
        client = nil
        tokenStore = nil
        try await super.tearDown()
    }

    private static func tokenPairBody(access: String, refresh: String) -> Data {
        Data(#"{"access_token":"\#(access)","refresh_token":"\#(refresh)","expires_in":3600,"token_type":"Bearer"}"#.utf8)
    }

    private func adoptExpiredSession() async {
        await client.adoptSession(TokenPair(accessToken: "at-1", refreshToken: "refresh-1", expiresAt: Date()))
    }

    /// 401 を受けたら refresh して 1 回だけ再送する
    func testUnauthorizedTriggersRefreshAndRetriesOnce() async throws {
        await adoptExpiredSession()
        recorder.respond { request in
            if request.url?.path == "/v1/auth/refresh" {
                return StubResponse(status: 200, body: ApiClientRefreshTests.tokenPairBody(access: "at-2", refresh: "refresh-2"))
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer at-2"
                ? StubResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
                : StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }

        struct Payload: Decodable, Sendable { let ok: Bool }
        let payload = try await client.send(.versioned(.get, "/identities"), as: Payload.self)

        XCTAssertTrue(payload.ok)
        XCTAssertEqual(recorder.count(path: "/v1/auth/refresh"), 1)
        XCTAssertEqual(recorder.count(path: "/v1/identities"), 2)
        // 回転式: 新しい refresh token を保存し直している
        let stored = await tokenStore.read()
        XCTAssertEqual(stored, "refresh-2")
    }

    /// AC-AUTH-08: 並行 401 でも refresh は 1 回だけ
    func testConcurrentUnauthorizedRefreshesOnlyOnce() async throws {
        await adoptExpiredSession()
        recorder.respond { request in
            if request.url?.path == "/v1/auth/refresh" {
                return StubResponse(
                    status: 200,
                    body: ApiClientRefreshTests.tokenPairBody(access: "at-2", refresh: "refresh-2"),
                    delay: 0.05
                )
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer at-2"
                ? StubResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
                : StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }

        struct Payload: Decodable, Sendable { let ok: Bool }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for path in ["/identities", "/memberships", "/applications", "/tours", "/events"] {
                group.addTask { [client] in
                    try await client!.send(.versioned(.get, path), as: Payload.self).ok
                }
            }
            for try await ok in group {
                XCTAssertTrue(ok)
            }
        }

        XCTAssertEqual(recorder.count(path: "/v1/auth/refresh"), 1)
    }

    /// 再送後の 401 はそのままエラー（無限ループしない）
    func testSecondUnauthorizedIsNotRetriedAgain() async throws {
        await adoptExpiredSession()
        recorder.respond { request in
            if request.url?.path == "/v1/auth/refresh" {
                return StubResponse(status: 200, body: ApiClientRefreshTests.tokenPairBody(access: "at-2", refresh: "refresh-2"))
            }
            return StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }

        struct Payload: Decodable, Sendable { let ok: Bool }
        do {
            _ = try await client.send(.versioned(.get, "/identities"), as: Payload.self)
            XCTFail("401 が伝播していない")
        } catch {
            XCTAssertEqual(error as? AppError, .unauthenticated)
        }
        XCTAssertEqual(recorder.count(path: "/v1/identities"), 2)
        XCTAssertEqual(recorder.count(path: "/v1/auth/refresh"), 1)
    }

    /// AC-AUTH-09: refresh が失効していたらサイレントログアウト（Keychain もクリア）
    func testInvalidRefreshTokenEndsSession() async throws {
        await adoptExpiredSession()
        let ended = SignalBox()
        await client.setSessionEndedHandler { await ended.signal() }
        recorder.respond { request in
            request.url?.path == "/v1/auth/refresh"
                ? StubResponse(status: 401, body: StubResponse.envelope("AUTH_REFRESH_INVALID"))
                : StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }

        struct Payload: Decodable, Sendable { let ok: Bool }
        do {
            _ = try await client.send(.versioned(.get, "/identities"), as: Payload.self)
            XCTFail("失効が伝播していない")
        } catch {
            XCTAssertEqual(error as? AppError, .sessionExpired)
        }
        let stored = await tokenStore.read()
        XCTAssertNil(stored)
        let didEnd = await ended.value
        XCTAssertTrue(didEnd)
    }

    /// AC-AUTH-05 の仕組み: メモリに access token が無くても Keychain の refresh token で復帰する
    func testColdStartRefreshesBeforeFirstRequest() async throws {
        recorder.respond { request in
            if request.url?.path == "/v1/auth/refresh" {
                return StubResponse(status: 200, body: ApiClientRefreshTests.tokenPairBody(access: "at-cold", refresh: "refresh-cold"))
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer at-cold"
                ? StubResponse(status: 200, body: Data(#"{"ok":true}"#.utf8))
                : StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }

        struct Payload: Decodable, Sendable { let ok: Bool }
        let payload = try await client.send(.versioned(.get, "/identities"), as: Payload.self)
        XCTAssertTrue(payload.ok)
        XCTAssertEqual(recorder.count(path: "/v1/identities"), 1)
        XCTAssertEqual(recorder.count(path: "/v1/auth/refresh"), 1)
    }

    /// `authorization: .none` は Bearer を付けず、401 でも refresh しない
    /// （サインイン失敗の 401 で自分のセッションを巻き込まない）
    func testUnauthenticatedEndpointDoesNotRefresh() async throws {
        await adoptExpiredSession()
        recorder.respond { _ in StubResponse(status: 401, body: StubResponse.envelope("AUTH_GOOGLE_INVALID")) }

        struct Payload: Decodable, Sendable { let ok: Bool }
        do {
            _ = try await client.send(.versioned(.post, "/auth/google"), as: Payload.self, authorization: .none)
            XCTFail("エラーが伝播していない")
        } catch {
            // `AUTH_GOOGLE_INVALID` を `AUTH_APPLE_INVALID` に丸めない
            XCTAssertEqual(error as? AppError, .googleSignInFailed)
        }
        XCTAssertEqual(recorder.count(path: "/v1/auth/refresh"), 0)
        XCTAssertNil(recorder.lastAuthorizationHeader(path: "/v1/auth/google") ?? nil)
    }

    // MARK: - ログアウトと refresh の競合（中-2）

    /// ログアウト中に完了した refresh が Keychain を書き戻さない。
    /// 書き戻すと次回起動で `restoreSession()` が成功し、**ログアウトしたユーザーが黙って復帰する**。
    func testRefreshCompletingAfterSignOutDoesNotRestoreToken() async throws {
        await adoptExpiredSession()
        recorder.respond { request in
            if request.url?.path == "/v1/auth/refresh" {
                return StubResponse(
                    status: 200,
                    body: ApiClientRefreshTests.tokenPairBody(access: "at-2", refresh: "refresh-2"),
                    delay: 0.2
                )
            }
            return StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }

        struct Payload: Decodable, Sendable { let ok: Bool }
        let inFlight = Task { [client] in
            try await client!.send(.versioned(.get, "/identities"), as: Payload.self)
        }
        // refresh が飛んでいる最中にログアウトする
        try await Task.sleep(nanoseconds: 60_000_000)
        await client.clearSession()

        _ = try? await inFlight.value
        // refresh の応答が届いても Keychain には書き戻らない
        let stored = await tokenStore.read()
        XCTAssertNil(stored, "ログアウト後に refresh の結果を採用してはいけない")
    }

    /// ログアウト後に開始した refresh は Keychain が空なのでセッション終了になる（既存の挙動の確認）。
    func testRequestAfterSignOutDoesNotReviveSession() async throws {
        await adoptExpiredSession()
        recorder.respond { request in
            request.url?.path == "/v1/auth/refresh"
                ? StubResponse(status: 200, body: ApiClientRefreshTests.tokenPairBody(access: "at-2", refresh: "refresh-2"))
                : StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }
        await client.clearSession()

        struct Payload: Decodable, Sendable { let ok: Bool }
        do {
            _ = try await client.send(.versioned(.get, "/identities"), as: Payload.self)
            XCTFail("ログアウト後のリクエストが通っている")
        } catch {
            XCTAssertEqual(error as? AppError, .sessionExpired)
        }
        let stored = await tokenStore.read()
        XCTAssertNil(stored)
    }

    /// 新しいセッションを採用した後に古い refresh が完了しても、新しい token を上書きしない。
    func testStaleRefreshDoesNotOverwriteNewerSession() async throws {
        await adoptExpiredSession()
        recorder.respond { request in
            if request.url?.path == "/v1/auth/refresh" {
                return StubResponse(
                    status: 200,
                    body: ApiClientRefreshTests.tokenPairBody(access: "at-old", refresh: "refresh-old"),
                    delay: 0.2
                )
            }
            return StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }

        struct Payload: Decodable, Sendable { let ok: Bool }
        let inFlight = Task { [client] in
            try await client!.send(.versioned(.get, "/identities"), as: Payload.self)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        // 別経路（サインイン / パスワード変更）で新しいセッションを採用
        await client.adoptSession(
            TokenPair(accessToken: "at-new", refreshToken: "refresh-new", expiresAt: Date().addingTimeInterval(3600))
        )

        _ = try? await inFlight.value
        let stored = await tokenStore.read()
        XCTAssertEqual(stored, "refresh-new", "古い refresh の結果で新しいセッションを上書きしない")
    }

    /// 中-2 残余: `store` 内の `await tokenStore.write` が中断している最中にログアウトが割り込んでも、
    /// 書き込み完了後に世代を再確認して打ち消すので、最終的に Keychain には何も残らない。
    /// （`tokenStore.write` 自体に遅延を入れて、ネットワーク往復ではなく Keychain 書き込みの中断点を再現する）
    func testWriteRaceWithLogoutEndsWithClearedToken() async throws {
        let delayedStore = DelayedWriteTokenStore(token: "refresh-1")
        let racingClient = ApiClient(
            configuration: ApiConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            tokenStore: delayedStore,
            session: StubURLProtocol.makeSession()
        )
        await racingClient.adoptSession(TokenPair(accessToken: "at-1", refreshToken: "refresh-1", expiresAt: Date()))
        await delayedStore.setWriteDelay(nanoseconds: 150_000_000)

        recorder.respond { request in
            request.url?.path == "/v1/auth/refresh"
                ? StubResponse(status: 200, body: ApiClientRefreshTests.tokenPairBody(access: "at-2", refresh: "refresh-2"))
                : StubResponse(status: 401, body: StubResponse.envelope("UNAUTHENTICATED"))
        }

        struct Payload: Decodable, Sendable { let ok: Bool }
        let inFlight = Task { [racingClient] in
            try await racingClient.send(.versioned(.get, "/identities"), as: Payload.self)
        }
        // refresh のネットワーク応答は即時。`store` が `tokenStore.write` で中断している間にログアウトする
        try await Task.sleep(nanoseconds: 60_000_000)
        await racingClient.clearSession()

        _ = try? await inFlight.value
        let stored = await delayedStore.read()
        XCTAssertNil(stored, "書き込み中のログアウトを打ち消して Keychain を空に戻すべき")
    }

    // MARK: - restoreSession

    func testRestoreWithoutStoredTokenIsSignedOutWithoutNetwork() async {
        let empty = ApiClient(
            configuration: ApiConfiguration(baseURL: URL(string: "http://localhost:8080")!),
            tokenStore: InMemoryTokenStore(),
            session: StubURLProtocol.makeSession()
        )
        recorder.respond { _ in StubResponse(status: 500, body: Data()) }
        let result = await empty.restoreSession()
        XCTAssertEqual(result, .signedOut)
        XCTAssertEqual(recorder.total, 0)
    }

    func testRestoreSucceeds() async {
        recorder.respond { _ in
            StubResponse(status: 200, body: ApiClientRefreshTests.tokenPairBody(access: "at-2", refresh: "refresh-2"))
        }
        let result = await client.restoreSession()
        XCTAssertEqual(result, .restored)
        let stored = await tokenStore.read()
        XCTAssertEqual(stored, "refresh-2")
    }

    /// オフライン起動でログアウトさせない（token を消さない）
    func testRestoreOfflineKeepsToken() async {
        recorder.fail(with: URLError(.notConnectedToInternet))
        let result = await client.restoreSession()
        XCTAssertEqual(result, .unavailable(.offline))
        let stored = await tokenStore.read()
        XCTAssertEqual(stored, "refresh-1")
    }

    func testRestoreWithRejectedTokenSignsOut() async {
        recorder.respond { _ in StubResponse(status: 401, body: StubResponse.envelope("AUTH_REFRESH_INVALID")) }
        let result = await client.restoreSession()
        XCTAssertEqual(result, .signedOut)
        let stored = await tokenStore.read()
        XCTAssertNil(stored)
    }
}

// MARK: - スタブ

struct StubResponse: Sendable {
    let status: Int
    let body: Data
    var delay: TimeInterval = 0

    static func envelope(_ code: String) -> Data {
        Data(#"{"code":"\#(code)","message":null,"request_id":"req-1"}"#.utf8)
    }
}

/// テスト用のリクエスト記録 + 応答定義。
final class StubRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) -> StubResponse)?
    private var failure: URLError?
    private var requests: [(path: String, authorization: String?)] = []

    func respond(_ handler: @escaping @Sendable (URLRequest) -> StubResponse) {
        lock.withLock { self.handler = handler }
    }

    func fail(with error: URLError) {
        lock.withLock { self.failure = error }
    }

    func record(_ request: URLRequest) -> Result<StubResponse, URLError> {
        lock.withLock {
            requests.append((request.url?.path ?? "", request.value(forHTTPHeaderField: "Authorization")))
            if let failure { return .failure(failure) }
            guard let handler else { return .success(StubResponse(status: 500, body: Data())) }
            return .success(handler(request))
        }
    }

    func count(path: String) -> Int {
        lock.withLock { requests.filter { $0.path == path }.count }
    }

    var total: Int {
        lock.withLock { requests.count }
    }

    func lastAuthorizationHeader(path: String) -> String?? {
        lock.withLock { requests.last { $0.path == path }?.authorization }
    }
}

/// `async` 境界をまたいでフラグを見るための箱。
actor SignalBox {
    private(set) var value = false
    func signal() { value = true }
}

/// `write(_:)` に任意の遅延を挟める `RefreshTokenStoring`。
/// `ApiClient.store(_:epoch:)` 内の `await tokenStore.write` という中断点を、
/// ネットワーク遅延に頼らず狙って再現するためのテスト専用モック。
actor DelayedWriteTokenStore: RefreshTokenStoring {
    private var token: String?
    private var writeDelayNanoseconds: UInt64 = 0

    init(token: String? = nil) {
        self.token = token
    }

    func setWriteDelay(nanoseconds: UInt64) {
        writeDelayNanoseconds = nanoseconds
    }

    func read() async -> String? { token }

    func write(_ newToken: String) async {
        if writeDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: writeDelayNanoseconds)
        }
        token = newToken
    }

    func clear() async {
        token = nil
    }
}

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var recorder: StubRecorder?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let recorder = StubURLProtocol.recorder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch recorder.record(request) {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let stub):
            if stub.delay > 0 {
                Thread.sleep(forTimeInterval: stub.delay)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
