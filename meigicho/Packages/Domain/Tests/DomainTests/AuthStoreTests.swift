import XCTest
@testable import Domain

/// ログインゲートと 2 方式のサインイン（`plan.md` §4.2）。
@MainActor
final class AuthStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AuthStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeStore(
        repository: FakeAuthRepository = FakeAuthRepository(),
        controller: FakeSessionController = FakeSessionController(),
        google: FakeGoogleSignIn? = nil
    ) -> AuthStore {
        AuthStore(repository: repository, session: controller, googleSignIn: google, userDefaults: defaults)
    }

    // MARK: - 起動

    func testBootstrapRestoresSession() async {
        let controller = FakeSessionController(restore: .restored)
        let store = makeStore(controller: controller)
        await store.bootstrap()
        XCTAssertEqual(store.state, .signedIn)
        XCTAssertNil(store.errorMessage)
    }

    /// AC-AUTH-09: 失効していたらログイン画面に戻る。**アラート用の文言は出さない**
    func testBootstrapWithInvalidTokenIsSilentSignOut() async {
        let store = makeStore(controller: FakeSessionController(restore: .signedOut))
        await store.bootstrap()
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.errorMessage)
    }

    /// オフラインは「失効」と区別する（文言を出し、token は消していない）
    func testBootstrapOfflineShowsMessage() async {
        let controller = FakeSessionController(restore: .unavailable(.offline))
        let store = makeStore(controller: controller)
        await store.bootstrap()
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertEqual(store.errorMessage, AppError.offline.userMessage)
        XCTAssertFalse(controller.didClear)
    }

    /// refresh が復帰不能になったらサイレントログアウトする（E-6）
    func testSessionEndedHandlerSignsOut() async {
        let controller = FakeSessionController(restore: .restored)
        let store = makeStore(controller: controller)
        await store.bootstrap()
        XCTAssertEqual(store.state, .signedIn)

        await controller.fireSessionEnded()
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.errorMessage)
    }

    // MARK: - Apple

    func testAppleSignInAdoptsServerIssuedAccountID() async {
        let repository = FakeAuthRepository()
        let controller = FakeSessionController()
        let store = makeStore(repository: repository, controller: controller)

        let nonce = store.beginAppleSignIn()
        await store.completeAppleSignIn(identityToken: "APPLE_JWT")

        XCTAssertEqual(store.state, .signedIn)
        XCTAssertEqual(store.accountID, "ACC-3F9A21")
        XCTAssertEqual(repository.appleCalls.count, 1)
        XCTAssertEqual(repository.appleCalls.first?.identityToken, "APPLE_JWT")
        // **認可リクエストに設定したのと同じ文字列**をそのまま送る（sha256 しない — Q4 / A2）
        XCTAssertEqual(repository.appleCalls.first?.nonce, nonce)
        XCTAssertTrue(controller.adopted.contains("access-token"))
    }

    func testAppleSignInFailureShowsAppleMessage() async {
        let repository = FakeAuthRepository()
        repository.appleError = .appleSignInFailed
        let store = makeStore(repository: repository)

        _ = store.beginAppleSignIn()
        await store.completeAppleSignIn(identityToken: "APPLE_JWT")

        XCTAssertEqual(store.state, .unknown)
        XCTAssertEqual(store.errorMessage, AppError.appleSignInFailed.userMessage)
    }

    // MARK: - Google

    func testGoogleSignInSendsIdTokenAndNonceUnchanged() async {
        let repository = FakeAuthRepository()
        let google = FakeGoogleSignIn(identity: GoogleIdentity(idToken: "GOOGLE_JWT", nonce: "NONCE-1"))
        let store = makeStore(repository: repository, google: google)

        await store.signInWithGoogle()

        XCTAssertEqual(store.state, .signedIn)
        XCTAssertEqual(repository.googleCalls.count, 1)
        // AC-GG-07: **加工せずそのまま**送る
        XCTAssertEqual(repository.googleCalls.first?.idToken, "GOOGLE_JWT")
        XCTAssertEqual(repository.googleCalls.first?.nonce, "NONCE-1")
        XCTAssertTrue(repository.appleCalls.isEmpty)
    }

    /// AC-GG-04: キャンセルはエラーにしない
    func testGoogleCancellationIsNotAnError() async {
        let repository = FakeAuthRepository()
        let store = makeStore(repository: repository, google: FakeGoogleSignIn(identity: nil))

        await store.signInWithGoogle()

        XCTAssertEqual(store.state, .unknown)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(repository.googleCalls.isEmpty)
    }

    /// AC-GG-05: `AUTH_GOOGLE_INVALID` は Apple の文言に丸めない
    func testGoogleInvalidShowsGoogleMessage() async {
        let repository = FakeAuthRepository()
        repository.googleError = .googleSignInFailed
        let store = makeStore(repository: repository, google: FakeGoogleSignIn(identity: GoogleIdentity(idToken: "J", nonce: "N")))

        await store.signInWithGoogle()

        XCTAssertEqual(store.errorMessage, AppError.googleSignInFailed.userMessage)
        XCTAssertNotEqual(store.errorMessage, AppError.appleSignInFailed.userMessage)
        XCTAssertEqual(store.state, .unknown)
    }

    func testGoogleUnavailableWhenClientIDMissing() async {
        let store = makeStore(google: nil)
        XCTAssertFalse(store.isGoogleAvailable)
        await store.signInWithGoogle()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.state, .unknown)
    }

    // MARK: - ログアウト

    func testSignOutRevokesRefreshTokenAndClears() async {
        let repository = FakeAuthRepository()
        let controller = FakeSessionController(restore: .restored, refreshToken: "refresh-1")
        let store = makeStore(repository: repository, controller: controller)

        _ = store.beginAppleSignIn()
        await store.completeAppleSignIn(identityToken: "APPLE_JWT")
        await store.signOut()

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.accountID)
        XCTAssertEqual(repository.loggedOutTokens, ["refresh-1"])
        XCTAssertTrue(controller.didClear)
    }

    // MARK: - アカウント削除

    /// AC-AD-01-M: 成功時は `signOut()` と同じ後始末を行うが、`logout` は呼ばない
    func testDeleteAccountSuccessClearsSessionWithoutCallingLogout() async throws {
        let repository = FakeAuthRepository()
        let controller = FakeSessionController(restore: .restored, refreshToken: "refresh-1")
        let store = makeStore(repository: repository, controller: controller)

        _ = store.beginAppleSignIn()
        await store.completeAppleSignIn(identityToken: "APPLE_JWT")
        XCTAssertEqual(store.state, .signedIn)

        try await store.deleteAccount(password: "correct horse", appleAuthorizationCode: nil)

        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.accountID)
        XCTAssertTrue(controller.didClear)
        XCTAssertEqual(repository.deleteAccountCalls.count, 1)
        XCTAssertEqual(repository.deleteAccountCalls.first?.password, "correct horse")
        XCTAssertNil(repository.deleteAccountCalls.first?.appleAuthorizationCode)
        // `POST /v1/auth/logout` は呼ばない（refresh 行はサーバー側で削除済み）
        XCTAssertTrue(repository.loggedOutTokens.isEmpty)
    }

    /// AC-AD-02-M: 失敗時は状態を変えずに throw する
    func testDeleteAccountFailureKeepsSessionAndThrows() async {
        let repository = FakeAuthRepository()
        repository.deleteAccountError = .credentialsInvalid
        let controller = FakeSessionController(restore: .restored, refreshToken: "refresh-1")
        let store = makeStore(repository: repository, controller: controller)

        _ = store.beginAppleSignIn()
        await store.completeAppleSignIn(identityToken: "APPLE_JWT")

        do {
            try await store.deleteAccount(password: "wrong", appleAuthorizationCode: nil)
            XCTFail("エラーが伝播していない")
        } catch {
            XCTAssertEqual(error as? AppError, .credentialsInvalid)
        }
        XCTAssertEqual(store.state, .signedIn)
        XCTAssertNotNil(store.accountID)
        XCTAssertFalse(controller.didClear)
    }

    /// AC-AD-03-M: `.notFound` は成功と同じ後始末を行ってから throw する
    func testDeleteAccountNotFoundStillClearsSessionThenThrows() async {
        let repository = FakeAuthRepository()
        repository.deleteAccountError = .notFound
        let controller = FakeSessionController(restore: .restored, refreshToken: "refresh-1")
        let store = makeStore(repository: repository, controller: controller)

        _ = store.beginAppleSignIn()
        await store.completeAppleSignIn(identityToken: "APPLE_JWT")

        do {
            try await store.deleteAccount(password: nil, appleAuthorizationCode: nil)
            XCTFail("エラーが伝播していない")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
        XCTAssertEqual(store.state, .signedOut)
        XCTAssertNil(store.accountID)
        XCTAssertTrue(controller.didClear)
    }

    /// AC-AD-03-M: 実行中の再入は `.busy` で弾き、repository を 2 回呼ばない
    /// （UI の `.disabled` だけに二重送信防止を依存させない — review.md 中-2）
    func testDeleteAccountRejectsReentryWhileBusy() async throws {
        let repository = FakeAuthRepository()
        let gate = AsyncGate()
        repository.deleteAccountGate = gate
        let store = makeStore(repository: repository)

        _ = store.beginAppleSignIn()
        await store.completeAppleSignIn(identityToken: "APPLE_JWT")

        // 1 回目をサーバー応答待ちで止める
        let first = Task { try await store.deleteAccount(password: "pw", appleAuthorizationCode: nil) }
        await gate.waitUntilEntered()
        XCTAssertTrue(store.isBusy)

        do {
            try await store.deleteAccount(password: "pw", appleAuthorizationCode: nil)
            XCTFail("二重実行が弾かれていない")
        } catch {
            XCTAssertEqual(error as? EmailCredentialError, .busy)
        }

        await gate.open()
        try await first.value

        XCTAssertEqual(repository.deleteAccountCalls.count, 1)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.state, .signedOut)
    }

    /// 再起動時にアカウント ID の表示が消えないようにする（トークンは保存しない）
    func testSignedInUserCacheKeepsAccountIDButNoTokens() async {
        let store = makeStore()
        _ = store.beginAppleSignIn()
        await store.completeAppleSignIn(identityToken: "APPLE_JWT")

        let restored = makeStore(controller: FakeSessionController(restore: .restored))
        await restored.bootstrap()
        XCTAssertEqual(restored.accountID, "ACC-3F9A21")

        let dump = defaults.dictionaryRepresentation().description
        XCTAssertFalse(dump.contains("access-token"))
        XCTAssertFalse(dump.contains("refresh-token"))
    }
}

// MARK: - フェイク

final class FakeAuthRepository: AuthRepository, @unchecked Sendable {
    struct SocialCall: Sendable {
        let identityToken: String
        let nonce: String?
        var idToken: String { identityToken }
    }

    struct DeleteAccountCall: Sendable {
        let password: String?
        let appleAuthorizationCode: String?
    }

    var appleCalls: [SocialCall] = []
    var googleCalls: [SocialCall] = []
    var loggedOutTokens: [String] = []
    var deleteAccountCalls: [DeleteAccountCall] = []
    var appleError: AppError?
    var googleError: AppError?
    var deleteAccountError: AppError?
    /// 「サーバー応答待ち」を再現するための門（二重実行テスト用）
    var deleteAccountGate: AsyncGate?

    static let session = AuthSession(
        tokens: TokenPair(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3540)
        ),
        user: SignedInUser(
            id: UUID(uuidString: "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f")!,
            accountID: "ACC-3F9A21",
            displayName: nil,
            plan: .free,
            isNew: false
        )
    )

    func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthSession {
        appleCalls.append(SocialCall(identityToken: identityToken, nonce: nonce))
        if let appleError { throw appleError }
        return Self.session
    }

    func signInWithGoogle(idToken: String, nonce: String?) async throws -> AuthSession {
        googleCalls.append(SocialCall(identityToken: idToken, nonce: nonce))
        if let googleError { throw googleError }
        return Self.session
    }

    func register(email: String, password: String) async throws -> AuthSession { Self.session }
    func login(email: String, password: String) async throws -> AuthSession { Self.session }
    func changePassword(current: String, new: String) async throws -> TokenPair { Self.session.tokens }
    func requestPasswordReset(email: String) async throws {}
    func resetPassword(email: String, code: String, newPassword: String) async throws -> AuthSession { Self.session }
    func refresh(refreshToken: String) async throws -> TokenPair { Self.session.tokens }
    func logout(refreshToken: String) async throws { loggedOutTokens.append(refreshToken) }
    func deleteAccount(password: String?, appleAuthorizationCode: String?) async throws {
        deleteAccountCalls.append(DeleteAccountCall(password: password, appleAuthorizationCode: appleAuthorizationCode))
        // 門で止めるのは 1 回目だけ（2 回目まで止めるとガード未実装時にテストがハングする）
        if deleteAccountCalls.count == 1 {
            await deleteAccountGate?.enterAndWait()
        }
        if let deleteAccountError { throw deleteAccountError }
    }
}

/// テスト用の門。`enterAndWait()` は `open()` されるまで待ち、
/// `waitUntilEntered()` は誰かが門に到達するまで待つ（sleep を使わない決定的な同期）。
actor AsyncGate {
    private var entered = false
    private var opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters = []
        for waiter in waiters { waiter.resume() }
        if opened { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func open() {
        opened = true
        let waiters = openWaiters
        openWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

final class FakeSessionController: AuthSessionController, @unchecked Sendable {
    private let restore: SessionRestoreResult
    private let refreshToken: String?
    private(set) var adopted: [String] = []
    private(set) var didClear = false
    private var handler: (@Sendable () async -> Void)?

    init(restore: SessionRestoreResult = .signedOut, refreshToken: String? = nil) {
        self.restore = restore
        self.refreshToken = refreshToken
    }

    func adoptSession(_ tokens: TokenPair) async { adopted.append(tokens.accessToken) }
    func clearSession() async { didClear = true }
    func restoreSession() async -> SessionRestoreResult { restore }
    func currentRefreshToken() async -> String? { refreshToken }
    func setSessionEndedHandler(_ handler: @escaping @Sendable () async -> Void) async { self.handler = handler }
    func fireSessionEnded() async { await handler?() }
}

final class FakeGoogleSignIn: GoogleSignInProviding, @unchecked Sendable {
    private let identity: GoogleIdentity?
    private let error: AppError?

    init(identity: GoogleIdentity?, error: AppError? = nil) {
        self.identity = identity
        self.error = error
    }

    func signIn() async throws -> GoogleIdentity? {
        if let error { throw error }
        return identity
    }
}
