import XCTest
@testable import Domain

@MainActor
final class AdGatekeeperTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeInput(
        plan: Plan = .free,
        inGracePeriod: Bool = false,
        isOnline: Bool = true,
        appLaunchedAt: Date? = nil,
        lastStatusChangeAt: Date? = nil,
        sessionImpressionCount: Int = 0,
        lastShownPlacement: AdPlacement? = nil,
        now: Date? = nil
    ) -> AdGatekeeper.Input {
        AdGatekeeper.Input(
            plan: plan,
            inGracePeriod: inGracePeriod,
            isOnline: isOnline,
            appLaunchedAt: appLaunchedAt ?? epoch.addingTimeInterval(-31),
            lastStatusChangeAt: lastStatusChangeAt,
            sessionImpressionCount: sessionImpressionCount,
            lastShownPlacement: lastShownPlacement,
            now: now ?? epoch
        )
    }

    // MARK: AC-AD-20

    func testACAD20_plusPlanNeverShowsAd() {
        let gatekeeper = AdGatekeeper()
        let input = makeInput(plan: .plus)
        XCTAssertFalse(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    func testACAD20_gracePeriodNeverShowsAd() {
        let gatekeeper = AdGatekeeper()
        let input = makeInput(plan: .free, inGracePeriod: true)
        XCTAssertFalse(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    // MARK: AC-AD-21

    func testACAD21_beforeLaunchCooldownHidesAd() {
        let gatekeeper = AdGatekeeper()
        let launchedAt = epoch.addingTimeInterval(-29.9)
        let input = makeInput(appLaunchedAt: launchedAt)
        XCTAssertFalse(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    func testACAD21_atLaunchCooldownShowsAd() {
        let gatekeeper = AdGatekeeper()
        let launchedAt = epoch.addingTimeInterval(-30.0)
        let input = makeInput(appLaunchedAt: launchedAt)
        XCTAssertTrue(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    // MARK: AC-AD-22

    func testACAD22_sessionImpressionLimitHidesAd() {
        let gatekeeper = AdGatekeeper()
        let input = makeInput(sessionImpressionCount: 3)
        XCTAssertFalse(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    func testACAD22_belowSessionImpressionLimitShowsAd() {
        let gatekeeper = AdGatekeeper()
        let input = makeInput(sessionImpressionCount: 2)
        XCTAssertTrue(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    // MARK: AC-AD-23

    func testACAD23_withinStatusChangeCooldownHidesAd() {
        let gatekeeper = AdGatekeeper()
        let statusChangedAt = epoch.addingTimeInterval(-59)
        let input = makeInput(lastStatusChangeAt: statusChangedAt)
        XCTAssertFalse(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    func testACAD23_afterStatusChangeCooldownShowsAd() {
        let gatekeeper = AdGatekeeper()
        let statusChangedAt = epoch.addingTimeInterval(-61)
        let input = makeInput(lastStatusChangeAt: statusChangedAt)
        XCTAssertTrue(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    // MARK: AC-AD-24

    func testACAD24_offlineHidesAd() {
        let gatekeeper = AdGatekeeper()
        let input = makeInput(isOnline: false)
        XCTAssertFalse(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    // MARK: AC-AD-25

    func testACAD25_consecutiveSamePlacementHidesAd() {
        let gatekeeper = AdGatekeeper()
        let input = makeInput(lastShownPlacement: .homeBottom)
        XCTAssertFalse(gatekeeper.shouldShow(.homeBottom, input: input))
    }

    func testACAD25_differentPlacementAfterShowingStillShows() {
        let gatekeeper = AdGatekeeper()
        let input = makeInput(lastShownPlacement: .homeBottom)
        XCTAssertTrue(gatekeeper.shouldShow(.identitiesBottom, input: input))
    }

    // MARK: AC-AD-26 (AdPlacement 型ガード)

    func testACAD26_onlyFiveAllowedPlacementsExist() {
        XCTAssertEqual(AdPlacement.allCases.count, 5)
    }

    func testACAD26_forbiddenPlacementCasesDoNotExist() {
        let forbiddenRawValues = [
            "applicationDetail", "sharePreview", "sharedBoard", "form", "statusChange",
        ]
        let existingRawValues = Set(AdPlacement.allCases.map(\.rawValue))
        for forbidden in forbiddenRawValues {
            XCTAssertFalse(
                existingRawValues.contains(forbidden),
                "禁止面 \(forbidden) が AdPlacement の case として存在してはいけない"
            )
            XCTAssertNil(
                AdPlacement(rawValue: forbidden),
                "禁止面 \(forbidden) が AdPlacement の case として構築できてはいけない"
            )
        }
    }

    // MARK: AC-AD-27 (禁止画面ソース走査)

    func testACAD27_forbiddenScreensContainNoAdSlotReference() throws {
        let forbiddenScreenRelativePaths = [
            "Features/Sources/Features/Detail/ApplicationDetailView.swift",
            "Features/Sources/Features/Forms/AddIdentityView.swift",
            "Features/Sources/Features/Forms/IdentityFormView.swift",
            "Features/Sources/Features/Forms/AddMembershipView.swift",
            "Features/Sources/Features/Forms/MembershipFormView.swift",
            "Features/Sources/Features/Forms/AddApplicationView.swift",
            "Features/Sources/Features/Forms/ApplicationFormView.swift",
            "Features/Sources/Features/Forms/SheetContentView.swift",
            "Features/Sources/Features/Share/SharePreviewView.swift",
            // `OpenSharedBoardView.swift`（token 貼り付け画面）は共有のアカウント招待制化で削除された。
            // 入口は受信箱（`SharedInbox`）とディープリンクだけ
            "Features/Sources/Features/SharedBoard/SharedBoardView.swift",
        ]

        let packagesDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DomainTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Domain
            .deletingLastPathComponent() // Packages

        for relativePath in forbiddenScreenRelativePaths {
            let fileURL = packagesDirectory.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertFalse(
                contents.contains("AdSlot"),
                "禁止画面 \(relativePath) に AdSlot への参照があってはいけない（F3）"
            )
        }
    }

    // MARK: AC-AD-39 補強 (表示中の枠の再判定 = shouldRemainVisible)

    /// 自分のインプレッションで F4-1 / F4-3 が反転しても、表示中の枠は消えない（ラッチの根拠）
    func testShouldRemainVisibleIgnoresOwnImpression() {
        let gatekeeper = AdGatekeeper()
        let input = makeInput(sessionImpressionCount: 3, lastShownPlacement: .identitiesBottom)
        XCTAssertFalse(gatekeeper.shouldShow(.identitiesBottom, input: input))
        XCTAssertTrue(gatekeeper.shouldRemainVisible(.identitiesBottom, input: input))
    }

    /// F4-5: 表示中でもステータス変更から 60 秒未満なら畳む
    func testShouldRemainVisibleFalseWithinStatusChangeCooldown() {
        let gatekeeper = AdGatekeeper()
        let input = makeInput(
            lastStatusChangeAt: epoch.addingTimeInterval(-59),
            sessionImpressionCount: 1,
            lastShownPlacement: .tourTableBetween
        )
        XCTAssertFalse(gatekeeper.shouldRemainVisible(.tourTableBetween, input: input))
    }

    /// F4-6: 表示中に Plus / grace になったら畳む
    func testShouldRemainVisibleFalseForPlusAndGrace() {
        let gatekeeper = AdGatekeeper()
        XCTAssertFalse(gatekeeper.shouldRemainVisible(.identitiesBottom, input: makeInput(plan: .plus)))
        XCTAssertFalse(
            gatekeeper.shouldRemainVisible(.identitiesBottom, input: makeInput(inGracePeriod: true))
        )
    }

    /// F4-4: 表示中にオフラインへ落ちたら畳む
    func testShouldRemainVisibleFalseWhenOffline() {
        let gatekeeper = AdGatekeeper()
        XCTAssertFalse(gatekeeper.shouldRemainVisible(.identitiesBottom, input: makeInput(isOnline: false)))
    }

    /// `AdsStore` 経由でも同じ判定になる（ツアー表でステータスを叩いた直後の挙動）
    func testAdsStoreShouldRemainVisibleAfterStatusChange() {
        let store = AdsStore(appLaunchedAt: epoch.addingTimeInterval(-100), now: { self.epoch })
        store.recordImpression(.tourTableBetween)
        XCTAssertTrue(store.shouldRemainVisible(.tourTableBetween))

        store.recordStatusChange(at: epoch.addingTimeInterval(-1))
        XCTAssertFalse(store.shouldRemainVisible(.tourTableBetween))
    }

    // MARK: AC-AD-28 (AdsStore セッションリセット)

    func testACAD28_backgroundUnder30SecondsKeepsSession() {
        let store = AdsStore(appLaunchedAt: epoch.addingTimeInterval(-100), now: { self.epoch })
        store.recordImpression(.homeBottom)
        XCTAssertEqual(store.sessionImpressionCount, 1)

        store.handleForegroundReturn(backgroundDuration: 29.9)

        XCTAssertEqual(store.sessionImpressionCount, 1)
        XCTAssertEqual(store.lastShownPlacement, .homeBottom)
    }

    func testACAD28_background30SecondsOrMoreResetsSession() {
        let store = AdsStore(appLaunchedAt: epoch.addingTimeInterval(-100), now: { self.epoch })
        store.recordImpression(.homeBottom)
        XCTAssertEqual(store.sessionImpressionCount, 1)

        store.handleForegroundReturn(backgroundDuration: 30.0)

        XCTAssertEqual(store.sessionImpressionCount, 0)
        XCTAssertNil(store.lastShownPlacement)
    }
}
