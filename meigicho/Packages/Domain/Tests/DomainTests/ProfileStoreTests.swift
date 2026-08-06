import XCTest
@testable import Domain

/// `GET/PATCH /v1/me`（`plan.md` §4.2b AC-ME-01〜04 / `contract-mapping.md` §4.2）。
@MainActor
final class ProfileStoreTests: XCTestCase {
    // MARK: - AC-ME-04: auth_providers

    /// **未知の値が増えてもクラッシュしない**。既知 3 値だけをラベル化する
    func testUnknownAuthProviderIsIgnoredNotCrashing() async {
        let repository = FakeProfileRepository(
            snapshot: Self.snapshot(authProviders: ["apple", "email", "line", "google"])
        )
        let store = ProfileStore(repository: repository)
        await store.load()

        XCTAssertEqual(store.authProviders, ["apple", "email", "line", "google"])
        XCTAssertEqual(store.authProviderLabels, ["Apple", "メールアドレス", "Google"])
    }

    /// AC-EM-10: `"email"` が無いアカウントでは「パスワードを変更」を出さない（叩くと 403）
    func testHasPasswordLoginOnlyWhenEmailProviderPresent() async {
        let appleOnly = ProfileStore(repository: FakeProfileRepository(snapshot: Self.snapshot(authProviders: ["apple"])))
        await appleOnly.load()
        XCTAssertFalse(appleOnly.hasPasswordLogin)

        let withEmail = ProfileStore(repository: FakeProfileRepository(snapshot: Self.snapshot(authProviders: ["apple", "email"])))
        await withEmail.load()
        XCTAssertTrue(withEmail.hasPasswordLogin)
    }

    // MARK: - 読み込み

    func testLoadPopulatesProfileAndEntitlement() async {
        let store = ProfileStore(repository: FakeProfileRepository(snapshot: Self.snapshot()))
        await store.load()

        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.accountID, "ACC-3F9A21")
        XCTAssertEqual(store.email, "fan@example.com")
        XCTAssertEqual(store.entitlement?.identityLimit, 3)
    }

    /// 失敗と「空」を区別する（E-1）
    func testLoadFailureKeepsStateFailed() async {
        let repository = FakeProfileRepository(snapshot: Self.snapshot())
        repository.fetchError = .offline
        let store = ProfileStore(repository: repository)
        await store.load()

        XCTAssertEqual(store.state, .failed(.offline))
        XCTAssertNil(store.profile)
    }

    /// 購入直後の Plus が `GET /v1/me`（まだ free）で巻き戻らない
    func testLoadMergesEntitlementPreferringLocalPlus() async {
        let repository = FakeProfileRepository(snapshot: Self.snapshot())
        let store = ProfileStore(repository: repository)
        await store.load()

        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        store.applyEntitlement(
            Entitlement(plan: .plus, expiresAt: expires, identityLimit: nil, shareLimit: nil)
        )
        await store.load()

        XCTAssertEqual(store.entitlement?.plan, .plus)
        XCTAssertEqual(store.entitlement?.expiresAt, expires)
        XCTAssertEqual(store.profile?.accountID, "ACC-3F9A21")
    }

    // MARK: - AC-ME-01 / AC-ME-02: 保存

    func testSaveUsernameSendsOnlyUsernameKey() async {
        let repository = FakeProfileRepository(snapshot: Self.snapshot())
        let store = ProfileStore(repository: repository)
        await store.load()

        let saved = await store.saveUsername(" yuya ")

        XCTAssertTrue(saved)
        let patch = repository.patches.last
        XCTAssertEqual(patch?.username, .set("yuya"))
        // 他のキーは送らない（BE は送られたキーのみ更新する）
        XCTAssertTrue(patch?.displayName.isUnchanged ?? false)
        XCTAssertTrue(patch?.themeColor.isUnchanged ?? false)
        XCTAssertTrue(patch?.appDisplayName.isUnchanged ?? false)
    }

    /// 空文字は BE の `@Length(1,30)` に落ちるので **`null`（クリア）** として送る
    func testEmptyUsernameIsSentAsNull() async {
        let repository = FakeProfileRepository(snapshot: Self.snapshot())
        let store = ProfileStore(repository: repository)
        await store.load()

        _ = await store.saveUsername("   ")

        XCTAssertEqual(repository.patches.last?.username, .set(nil))
    }

    /// AC-ME-02: `theme_color` は `^#[0-9A-Fa-f]{6}$` に合うときだけ送る
    func testInvalidThemeColorIsNotSent() async {
        let repository = FakeProfileRepository(snapshot: Self.snapshot())
        let store = ProfileStore(repository: repository)
        await store.load()

        let saved = await store.saveThemeColor("blue")

        XCTAssertFalse(saved)
        XCTAssertTrue(repository.patches.isEmpty)
    }

    func testValidThemeColorIsSent() async {
        let repository = FakeProfileRepository(snapshot: Self.snapshot())
        let store = ProfileStore(repository: repository)
        await store.load()

        let saved = await store.saveThemeColor("#FF00AA")

        XCTAssertTrue(saved)
        XCTAssertEqual(repository.patches.last?.themeColor, .set("#FF00AA"))
    }

    /// 同じ色を選び直しただけなら往復しない
    func testUnchangedThemeColorSkipsRequest() async {
        let repository = FakeProfileRepository(snapshot: Self.snapshot())
        let store = ProfileStore(repository: repository)
        await store.load()

        _ = await store.saveThemeColor("#0017C1")

        XCTAssertTrue(repository.patches.isEmpty)
    }

    func testSaveFailureExposesMessageAndReturnsFalse() async {
        let repository = FakeProfileRepository(snapshot: Self.snapshot())
        repository.updateError = .offline
        let store = ProfileStore(repository: repository)
        await store.load()

        let saved = await store.saveUsername("yuya")

        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, AppError.offline.userMessage)
    }

    /// ログアウト時に前のアカウントの情報を残さない
    func testClearRemovesEverything() async {
        let store = ProfileStore(repository: FakeProfileRepository(snapshot: Self.snapshot()))
        await store.load()
        store.clear()

        XCTAssertNil(store.profile)
        XCTAssertNil(store.entitlement)
        XCTAssertEqual(store.state, .idle)
    }

    // MARK: - Helper

    static func snapshot(authProviders: [String] = ["apple"]) -> MeSnapshot {
        MeSnapshot(
            profile: UserProfile(
                userID: UUID(uuidString: "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f")!,
                accountID: "ACC-3F9A21",
                displayName: nil,
                username: nil,
                appDisplayName: nil,
                themeColor: "#0017C1",
                locale: "ja_JP",
                timezone: "Asia/Tokyo",
                onboardedAt: nil,
                email: "fan@example.com",
                authProviders: authProviders
            ),
            entitlement: Entitlement(plan: .free, identityLimit: 3, shareLimit: 1)
        )
    }
}

final class FakeProfileRepository: ProfileRepository, @unchecked Sendable {
    private var snapshot: MeSnapshot
    private(set) var patches: [ProfilePatch] = []
    var fetchError: AppError?
    var updateError: AppError?

    init(snapshot: MeSnapshot) {
        self.snapshot = snapshot
    }

    func fetchMe() async throws -> MeSnapshot {
        if let fetchError { throw fetchError }
        return snapshot
    }

    func updateMe(_ patch: ProfilePatch) async throws -> MeSnapshot {
        patches.append(patch)
        if let updateError { throw updateError }
        var profile = snapshot.profile
        profile.username = patch.username.applied(to: profile.username)
        profile.appDisplayName = patch.appDisplayName.applied(to: profile.appDisplayName)
        profile.themeColor = patch.themeColor.applied(to: profile.themeColor) ?? profile.themeColor
        snapshot = MeSnapshot(profile: profile, entitlement: snapshot.entitlement)
        return snapshot
    }
}
