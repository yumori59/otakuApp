import XCTest
@testable import Domain

/// `IdentityStore.existingFanClubNames`（`docs/plans/input-history-suggestions/plan.md` T5・AC-SG-17-T）。
@MainActor
final class IdentityStoreSuggestionTests: XCTestCase {
    func testExistingFanClubNamesDedupesTrimsAndSorts() {
        let identityID = UUID(uuidString: "00000000-0000-7000-8000-000000000001")!
        let store = IdentityStore()
        store.memberships = [
            makeMembership(identityID: identityID, fanClubNameRaw: "STELLARIS OFFICIAL FAN CLUB"),
            makeMembership(identityID: identityID, fanClubNameRaw: "STELLARIS OFFICIAL FAN CLUB"),
            makeMembership(identityID: identityID, fanClubNameRaw: ""),
            makeMembership(identityID: identityID, fanClubNameRaw: "   "),
            makeMembership(identityID: identityID, fanClubNameRaw: "AURORA FAN CLUB")
        ]

        XCTAssertEqual(store.existingFanClubNames, ["AURORA FAN CLUB", "STELLARIS OFFICIAL FAN CLUB"])
    }

    func testExistingFanClubNamesEmptyWhenNoMemberships() {
        let store = IdentityStore()
        store.memberships = []

        XCTAssertEqual(store.existingFanClubNames, [String]())
    }

    private func makeMembership(identityID: UUID, fanClubNameRaw: String) -> Membership {
        Membership(identityID: identityID, fanClubNameRaw: fanClubNameRaw, memberNoLast4: nil, renewalOn: nil, feeYen: nil)
    }
}
