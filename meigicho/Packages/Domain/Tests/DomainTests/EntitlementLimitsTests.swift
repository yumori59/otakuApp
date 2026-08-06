import XCTest
@testable import Domain

final class EntitlementLimitsTests: XCTestCase {
    func testCanAddIdentityRespectsLimit() {
        let free = Entitlement(plan: .free, identityLimit: 3, shareLimit: 1)
        XCTAssertTrue(free.canAddIdentity(currentCount: 2))
        XCTAssertFalse(free.canAddIdentity(currentCount: 3))
    }

    func testPlusHasNoIdentityLimit() {
        let plus = Entitlement(plan: .plus, identityLimit: nil, shareLimit: nil)
        XCTAssertTrue(plus.canAddIdentity(currentCount: 100))
    }

    func testCanCreateShareLinkRespectsLimit() {
        let free = Entitlement(plan: .free, identityLimit: 3, shareLimit: 1)
        XCTAssertTrue(free.canCreateShareLink(activeLinkCount: 0))
        XCTAssertFalse(free.canCreateShareLink(activeLinkCount: 1))
    }

    /// Webhook 未到着: local Plus を free ミラーで上書きしない（docs/07 §9.2）
    func testMergeKeepsLocalPlusWhenRemoteStillFree() {
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let local = Entitlement(plan: .plus, expiresAt: expires, identityLimit: nil, shareLimit: nil)
        let remote = Entitlement(plan: .free, bonusIdentitySlots: 1, identityLimit: 3, shareLimit: 1)
        let merged = Entitlement.mergingPreferringLongerAccess(local: local, remote: remote)
        XCTAssertEqual(merged.plan, .plus)
        XCTAssertEqual(merged.expiresAt, expires)
        XCTAssertEqual(merged.bonusIdentitySlots, 1)
    }

    func testMergePrefersRemoteWhenRemoteExpiresLater() {
        let local = Entitlement(
            plan: .plus,
            expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            identityLimit: nil,
            shareLimit: nil
        )
        let remote = Entitlement(
            plan: .plus,
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            identityLimit: nil,
            shareLimit: nil
        )
        let merged = Entitlement.mergingPreferringLongerAccess(local: local, remote: remote)
        XCTAssertEqual(merged.expiresAt, remote.expiresAt)
    }
}
