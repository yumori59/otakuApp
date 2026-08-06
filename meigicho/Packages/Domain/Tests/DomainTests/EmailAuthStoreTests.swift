import XCTest
@testable import Domain

/// メール + パスワード認証（`plan.md` §4.2b / `contract-mapping.md` §4.1 A3〜A11）。
@MainActor
final class EmailAuthStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "EmailAuthStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    private func makeStore(
        repository: RecordingAuthRepository = RecordingAuthRepository(),
        controller: FakeSessionController = FakeSessionController()
    ) -> AuthStore {
        AuthStore(repository: repository, session: controller, googleSignIn: nil, userDefaults: defaults)
    }

    // MARK: - AC-EM-03 / AC-EM-04: 入力規則

    /// AC-EM-03: パスワードは **8〜128 文字のみ**。大文字必須などの独自ルールを足さない（IOS-4）
    func testPasswordRuleIsLengthOnly() {
        XCTAssertFalse(EmailCredentialRule.isValidPassword(String(repeating: "a", count: 7)))
        XCTAssertTrue(EmailCredentialRule.isValidPassword(String(repeating: "a", count: 8)))
        XCTAssertTrue(EmailCredentialRule.isValidPassword(String(repeating: "a", count: 128)))
        XCTAssertFalse(EmailCredentialRule.isValidPassword(String(repeating: "a", count: 129)))

        // 文字種の要件は無い（小文字だけ / 数字だけ / 記号だけ / 日本語 でも通る）
        XCTAssertTrue(EmailCredentialRule.isValidPassword("aaaaaaaa"))
        XCTAssertTrue(EmailCredentialRule.isValidPassword("12345678"))
        XCTAssertTrue(EmailCredentialRule.isValidPassword("!!!!!!!!"))
        XCTAssertTrue(EmailCredentialRule.isValidPassword("ぱすわーど８文字"))
        XCTAssertTrue(EmailCredentialRule.isValidPassword("correct horse battery"))
    }

    /// AC-EM-04: リセットコードは `^\d{8}$`
    func testResetCodeRule() {
        XCTAssertTrue(EmailCredentialRule.isValidResetCode("48210937"))
        XCTAssertFalse(EmailCredentialRule.isValidResetCode("4821093"))
        XCTAssertFalse(EmailCredentialRule.isValidResetCode("482109371"))
        XCTAssertFalse(EmailCredentialRule.isValidResetCode("4821093a"))
        XCTAssertFalse(EmailCredentialRule.isValidResetCode(""))
        // 全角数字は通さない
        XCTAssertFalse(EmailCredentialRule.isValidResetCode("４８２１０９３７"))
    }

    /// A10: 正規化（小文字化）は**サーバーの担当**。iOS は trim だけする
    func testEmailIsTrimmedButNotLowercased() {
        XCTAssertEqual(EmailCredentialRule.normalizedEmail("  Fan@Example.com "), "Fan@Example.com")
        XCTAssertTrue(EmailCredentialRule.isValidEmail(" fan@example.com "))
        XCTAssertFalse(EmailCredentialRule.isValidEmail("fan"))
        XCTAssertFalse(EmailCredentialRule.isValidEmail("fan@example"))
        XCTAssertFalse(EmailCredentialRule.isValidEmail("@example.com"))
        XCTAssertFalse(EmailCredentialRule.isValidEmail(String(repeating: "a", count: 250) + "@example.com"))
    }

    // MARK: - register / login

    /// AC-EM-05: 登録に成功すると**そのままログイン状態になる**
    func testRegisterAdoptsSessionAndSignsIn() async throws {
        let repository = RecordingAuthRepository()
        let controller = FakeSessionController()
        let store = makeStore(repository: repository, controller: controller)

        try await store.registerWithEmail(email: " Fan@Example.com ", password: "correct horse")

        XCTAssertEqual(store.state, .signedIn)
        XCTAssertEqual(repository.registerCalls.count, 1)
        // trim だけして送る（小文字化しない）
        XCTAssertEqual(repository.registerCalls.first?.email, "Fan@Example.com")
        XCTAssertEqual(repository.registerCalls.first?.password, "correct horse")
        XCTAssertTrue(controller.adopted.contains("access-token"))
        XCTAssertTrue(repository.loginCalls.isEmpty)
    }

    /// AC-EM-06: `EMAIL_ALREADY_REGISTERED` はそのまま伝える（ログインの文言に丸めない）
    func testRegisterConflictThrowsEmailAlreadyRegistered() async {
        let repository = RecordingAuthRepository()
        repository.registerError = .emailAlreadyRegistered
        let store = makeStore(repository: repository)

        do {
            try await store.registerWithEmail(email: "fan@example.com", password: "correct horse")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppError, .emailAlreadyRegistered)
        }
        XCTAssertEqual(store.state, .unknown)
    }

    /// 送信前に弾いた入力エラーはサーバーに飛ばさない（往復を減らす。文言は別系統）
    func testRegisterWithShortPasswordDoesNotCallServer() async {
        let repository = RecordingAuthRepository()
        let store = makeStore(repository: repository)

        do {
            try await store.registerWithEmail(email: "fan@example.com", password: "short")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? EmailCredentialError, .passwordLength)
        }
        XCTAssertTrue(repository.registerCalls.isEmpty)
    }

    /// AC-EM-07: `AUTH_CREDENTIALS_INVALID` は未登録 / 誤パスワードを**区別しない**
    func testLoginFailureIsIndistinguishable() async {
        let repository = RecordingAuthRepository()
        repository.loginError = .credentialsInvalid
        let store = makeStore(repository: repository)

        do {
            try await store.signInWithEmail(email: "fan@example.com", password: "wrong password")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppError, .credentialsInvalid)
            XCTAssertEqual((error as? AppError)?.userMessage, "メールアドレスまたはパスワードが違います")
        }
        XCTAssertEqual(store.state, .unknown)
    }

    /// ログインは**パスワードの下限を掛けない**（旧ポリシーのアカウントを 401 と区別できてしまうため）
    func testLoginDoesNotEnforceMinimumPasswordLength() async throws {
        let repository = RecordingAuthRepository()
        let store = makeStore(repository: repository)

        try await store.signInWithEmail(email: "fan@example.com", password: "short")

        XCTAssertEqual(repository.loginCalls.count, 1)
        XCTAssertEqual(repository.loginCalls.first?.password, "short")
        XCTAssertEqual(store.state, .signedIn)
    }

    // MARK: - AC-EM-08 / R9: パスワード変更

    /// **返ってきたトークンペアを Keychain に上書きする**（捨てると自分自身が次の refresh で落ちる — A5）
    func testChangePasswordAdoptsRotatedTokens() async throws {
        let repository = RecordingAuthRepository()
        let controller = FakeSessionController()
        let store = makeStore(repository: repository, controller: controller)

        try await store.changePassword(current: "old password", new: "a brand new one")

        XCTAssertEqual(repository.changePasswordCalls.count, 1)
        XCTAssertEqual(controller.adopted, ["rotated-access-token"])
    }

    /// `current_password === new_password` はサーバーが 400。送信前に弾く
    func testChangePasswordRejectsSameValue() async {
        let repository = RecordingAuthRepository()
        let store = makeStore(repository: repository)

        do {
            try await store.changePassword(current: "same password", new: "same password")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? EmailCredentialError, .newPasswordSameAsCurrent)
        }
        XCTAssertTrue(repository.changePasswordCalls.isEmpty)
    }

    /// 失敗時はトークンを差し替えない（現行セッションを壊さない）
    func testChangePasswordFailureKeepsSession() async {
        let repository = RecordingAuthRepository()
        repository.changePasswordError = .credentialsInvalid
        let controller = FakeSessionController()
        let store = makeStore(repository: repository, controller: controller)

        do {
            try await store.changePassword(current: "wrong", new: "a brand new one")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppError, .credentialsInvalid)
        }
        XCTAssertTrue(controller.adopted.isEmpty)
        XCTAssertFalse(controller.didClear)
    }

    // MARK: - AC-EM-11 / AC-EM-12 / AC-EM-14: リセット

    /// 202 は「送った」ではなく「受け付けた」。**成功でも状態は変えない**（A4）
    func testResetRequestDoesNotChangeAuthState() async throws {
        let repository = RecordingAuthRepository()
        let store = makeStore(repository: repository)

        try await store.requestPasswordReset(email: " fan@example.com ")

        XCTAssertEqual(repository.resetRequestEmails, ["fan@example.com"])
        XCTAssertEqual(store.state, .unknown)
    }

    /// AC-EM-14: 429 は伝えるだけ。**自動リトライしない**（呼び出しは 1 回のまま）
    func testResetRequestRateLimitedDoesNotRetry() async {
        let repository = RecordingAuthRepository()
        repository.resetRequestError = .rateLimited
        let store = makeStore(repository: repository)

        do {
            try await store.requestPasswordReset(email: "fan@example.com")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppError, .rateLimited)
        }
        XCTAssertEqual(repository.resetRequestEmails.count, 1)
    }

    /// AC-EM-12: リセット成功で**そのままログイン状態になる**（A6）
    func testResetPasswordSignsIn() async throws {
        let repository = RecordingAuthRepository()
        let controller = FakeSessionController()
        let store = makeStore(repository: repository, controller: controller)

        try await store.resetPassword(email: "fan@example.com", code: "48210937", newPassword: "a brand new one")

        XCTAssertEqual(store.state, .signedIn)
        XCTAssertEqual(repository.resetCalls.first?.code, "48210937")
        XCTAssertTrue(controller.adopted.contains("access-token"))
    }

    /// AC-EM-13: 誤コードは常に同じエラー（試行超過と区別しない）
    func testResetPasswordInvalidCodeIsAlwaysTheSameError() async {
        let repository = RecordingAuthRepository()
        repository.resetError = .resetCodeInvalid
        let store = makeStore(repository: repository)

        do {
            try await store.resetPassword(email: "fan@example.com", code: "00000000", newPassword: "a brand new one")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? AppError, .resetCodeInvalid)
            XCTAssertEqual((error as? AppError)?.userMessage, "コードが正しくないか、有効期限が切れています")
        }
    }

    func testResetPasswordRejectsMalformedCodeBeforeSending() async {
        let repository = RecordingAuthRepository()
        let store = makeStore(repository: repository)

        do {
            try await store.resetPassword(email: "fan@example.com", code: "1234", newPassword: "a brand new one")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? EmailCredentialError, .resetCodeFormat)
        }
        XCTAssertTrue(repository.resetCalls.isEmpty)
    }
}

// MARK: - フェイク

/// メール系 5 経路の呼び出しを記録する。
/// `AuthStoreTests` の `FakeAuthRepository`（Apple / Google 用）とは別に持つ。
final class RecordingAuthRepository: AuthRepository, @unchecked Sendable {
    struct Credentials: Sendable {
        let email: String
        let password: String
    }

    struct ResetCall: Sendable {
        let email: String
        let code: String
        let newPassword: String
    }

    struct ChangeCall: Sendable {
        let current: String
        let new: String
    }

    var registerCalls: [Credentials] = []
    var loginCalls: [Credentials] = []
    var changePasswordCalls: [ChangeCall] = []
    var resetRequestEmails: [String] = []
    var resetCalls: [ResetCall] = []

    var registerError: AppError?
    var loginError: AppError?
    var changePasswordError: AppError?
    var resetRequestError: AppError?
    var resetError: AppError?

    static let session = AuthSession(
        tokens: TokenPair(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3540)
        ),
        user: SignedInUser(
            id: UUID(uuidString: "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f")!,
            accountID: "ACC-7C21A0",
            displayName: nil,
            plan: .free,
            isNew: true
        )
    )

    /// `POST /v1/auth/password` はサーバーが refresh を全件失効させて**新しい 1 本**を返す
    static let rotatedTokens = TokenPair(
        accessToken: "rotated-access-token",
        refreshToken: "rotated-refresh-token",
        expiresAt: Date().addingTimeInterval(3540)
    )

    func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthSession { Self.session }
    func signInWithGoogle(idToken: String, nonce: String?) async throws -> AuthSession { Self.session }

    func register(email: String, password: String) async throws -> AuthSession {
        registerCalls.append(Credentials(email: email, password: password))
        if let registerError { throw registerError }
        return Self.session
    }

    func login(email: String, password: String) async throws -> AuthSession {
        loginCalls.append(Credentials(email: email, password: password))
        if let loginError { throw loginError }
        return Self.session
    }

    func changePassword(current: String, new: String) async throws -> TokenPair {
        changePasswordCalls.append(ChangeCall(current: current, new: new))
        if let changePasswordError { throw changePasswordError }
        return Self.rotatedTokens
    }

    func requestPasswordReset(email: String) async throws {
        resetRequestEmails.append(email)
        if let resetRequestError { throw resetRequestError }
    }

    func resetPassword(email: String, code: String, newPassword: String) async throws -> AuthSession {
        resetCalls.append(ResetCall(email: email, code: code, newPassword: newPassword))
        if let resetError { throw resetError }
        return Self.session
    }

    func refresh(refreshToken: String) async throws -> TokenPair { Self.session.tokens }
    func logout(refreshToken: String) async throws {}
    func deleteAccount(password: String?, appleAuthorizationCode: String?) async throws {}
}
