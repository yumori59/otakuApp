import XCTest
@testable import Domain

/// `docs/plans/identity-grouping/` AC-IG-01〜11
@MainActor
final class FanClubGroupingTests: XCTestCase {
    private let today = Date(timeIntervalSince1970: 1_785_000_000) // 2026-07-31 前後
    private let identityA = UUID(uuidString: "00000000-0000-7000-8000-0000000000A1")!
    private let identityB = UUID(uuidString: "00000000-0000-7000-8000-0000000000B1")!
    private let identityC = UUID(uuidString: "00000000-0000-7000-8000-0000000000C1")!

    // MARK: - AC-IG-04 / AC-IG-05: 正規化

    func testFanClubGroupKeyCollapsesWhitespaceAndCase() {
        XCTAssertEqual(
            FanClubGrouping.fanClubGroupKey("STELLARIS FC"),
            FanClubGrouping.fanClubGroupKey(" stellaris fc ")
        )
        XCTAssertEqual(
            FanClubGrouping.fanClubGroupKey("STELLARIS FC"),
            FanClubGrouping.fanClubGroupKey("ＳＴＥＬＬＡＲＩＳ　ＦＣ")
        )
    }

    func testFanClubGroupKeyDoesNotFoldDiacriticsOrKana() {
        XCTAssertNotEqual(
            FanClubGrouping.fanClubGroupKey("ハルカ"),
            FanClubGrouping.fanClubGroupKey("バルカ")
        )
        XCTAssertNotEqual(
            FanClubGrouping.fanClubGroupKey("あいうえお"),
            FanClubGrouping.fanClubGroupKey("アイウエオ")
        )
    }

    func testBlankFanClubNameIsUnregisteredKey() {
        XCTAssertTrue(FanClubGrouping.isUnregisteredKey("   "))
        XCTAssertTrue(FanClubGrouping.isUnregisteredKey(""))
    }

    // MARK: - AC-IG-01: 単一FC

    func testSingleFanClubProducesOneGroupWithOneRow() {
        let store = makeStore()
        store.identities = [identity(id: identityA, name: "A")]
        store.memberships = [
            membership(id: UUID(), identityID: identityA, fc: "STELLARIS FC", renewalOn: day(2026, 9, 1)),
        ]

        let groups = store.groupedByFanClub(sortedBy: .renewalSoon, winCounts: [:])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.count, 1)
        XCTAssertEqual(groups[0].displayName, "STELLARIS FC")
    }

    // MARK: - AC-IG-02: 複数FC所属

    func testIdentityAppearsInEveryFanClubGroup() {
        let store = makeStore()
        store.identities = [identity(id: identityA, name: "A")]
        store.memberships = [
            membership(id: UUID(), identityID: identityA, fc: "FC Alpha", renewalOn: day(2026, 9, 1)),
            membership(id: UUID(), identityID: identityA, fc: "FC Beta", renewalOn: day(2026, 10, 1)),
        ]

        let groups = store.groupedByFanClub(sortedBy: .renewalSoon, winCounts: [:])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.flatMap(\.rows).count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.rows.count == 1 })
        XCTAssertEqual(Set(groups.flatMap(\.rows).map(\.identity.id)), [identityA])
    }

    // MARK: - AC-IG-03 / AC-IG-07 / AC-IG-11

    func testUnregisteredGroupIsLast() {
        let store = makeStore()
        store.identities = [
            identity(id: identityA, name: "A"),
            identity(id: identityB, name: "B"),
        ]
        store.memberships = [
            membership(id: UUID(), identityID: identityA, fc: "FC Alpha", renewalOn: day(2026, 9, 1)),
        ]

        let groups = store.groupedByFanClub(sortedBy: .renewalSoon, winCounts: [:])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.last?.displayName, "FC未登録")
        XCTAssertEqual(groups.last?.rows.map(\.identity.id), [identityB])
    }

    func testOnlyUnregisteredWhenNoMemberships() {
        let store = makeStore()
        store.identities = [identity(id: identityA, name: "A")]

        let groups = store.groupedByFanClub(sortedBy: .renewalSoon, winCounts: [:])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayName, "FC未登録")
        XCTAssertEqual(groups[0].rows.count, 1)
    }

    // MARK: - AC-IG-04: 表示名は最初の原文

    func testDisplayNameKeepsFirstOriginalFanClubName() {
        let store = makeStore()
        store.identities = [identity(id: identityA, name: "A")]
        store.memberships = [
            membership(id: UUID(), identityID: identityA, fc: "STELLARIS FC", renewalOn: day(2026, 9, 1)),
            membership(id: UUID(), identityID: identityB, fc: " stellaris fc ", renewalOn: day(2026, 10, 1)),
        ]
        store.identities.append(identity(id: identityB, name: "B"))

        let groups = store.groupedByFanClub(sortedBy: .renewalSoon, winCounts: [:])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].displayName, "STELLARIS FC")
        XCTAssertEqual(groups[0].rows.count, 2)
    }

    // MARK: - AC-IG-06: グループ順

    func testGroupOrderByNearestRenewalOn() {
        let store = makeStore()
        store.identities = [
            identity(id: identityA, name: "A"),
            identity(id: identityB, name: "B"),
        ]
        store.memberships = [
            membership(id: UUID(), identityID: identityA, fc: "Later FC", renewalOn: day(2026, 12, 1)),
            membership(id: UUID(), identityID: identityB, fc: "Soon FC", renewalOn: day(2026, 8, 15)),
        ]

        let groups = store.groupedByFanClub(sortedBy: .renewalSoon, winCounts: [:])

        XCTAssertEqual(groups.map(\.displayName), ["Soon FC", "Later FC"])
    }

    func testGroupsWithOnlyNilRenewalSortAfterOnesWithDates() {
        let store = makeStore()
        store.identities = [
            identity(id: identityA, name: "A"),
            identity(id: identityB, name: "B"),
        ]
        store.memberships = [
            membership(id: UUID(), identityID: identityA, fc: "Dated FC", renewalOn: day(2026, 9, 1)),
            membership(id: UUID(), identityID: identityB, fc: "No Date FC", renewalOn: nil),
        ]

        let groups = store.groupedByFanClub(sortedBy: .renewalSoon, winCounts: [:])

        XCTAssertEqual(groups.map(\.displayName), ["Dated FC", "No Date FC"])
    }

    // MARK: - AC-IG-08: renewalSoon は行ごとの renewalOn

    func testRenewalSoonSortUsesMembershipRenewalPerGroup() {
        let store = makeStore()
        store.identities = [identity(id: identityA, name: "A")]
        store.memberships = [
            membership(id: UUID(), identityID: identityA, fc: "Soon FC", renewalOn: day(2026, 8, 10)),
            membership(id: UUID(), identityID: identityA, fc: "Later FC", renewalOn: day(2026, 12, 1)),
        ]

        let groups = store.groupedByFanClub(sortedBy: .renewalSoon, winCounts: [:])
        let soonGroup = groups.first { $0.displayName == "Soon FC" }
        let laterGroup = groups.first { $0.displayName == "Later FC" }

        XCTAssertEqual(soonGroup?.rows.first?.membership?.renewalOn, day(2026, 8, 10))
        XCTAssertEqual(laterGroup?.rows.first?.membership?.renewalOn, day(2026, 12, 1))
    }

    // MARK: - AC-IG-09: mostWins / joinedOldest

    func testMostWinsSortWithinGroup() {
        let store = makeStore()
        store.identities = [
            identity(id: identityA, name: "A", joinedOn: day(2020, 1, 1)),
            identity(id: identityB, name: "B", joinedOn: day(2021, 1, 1)),
        ]
        store.memberships = [
            membership(id: UUID(), identityID: identityA, fc: "Same FC", renewalOn: nil),
            membership(id: UUID(), identityID: identityB, fc: "Same FC", renewalOn: nil),
        ]

        let groups = store.groupedByFanClub(
            sortedBy: .mostWins,
            winCounts: [identityA: 1, identityB: 5]
        )

        XCTAssertEqual(groups[0].rows.map(\.identity.id), [identityB, identityA])
    }

    func testJoinedOldestSortWithinGroup() {
        let store = makeStore()
        store.identities = [
            identity(id: identityA, name: "A", joinedOn: day(2022, 1, 1)),
            identity(id: identityB, name: "B", joinedOn: day(2020, 1, 1)),
        ]
        store.memberships = [
            membership(id: UUID(), identityID: identityA, fc: "Same FC", renewalOn: nil),
            membership(id: UUID(), identityID: identityB, fc: "Same FC", renewalOn: nil),
        ]

        let groups = store.groupedByFanClub(sortedBy: .joinedOldest, winCounts: [:])

        XCTAssertEqual(groups[0].rows.map(\.identity.id), [identityB, identityA])
    }

    // MARK: - AC-IG-10: 重複会員情報の畳み込み

    func testDuplicateMembershipsForSameIdentityAndFanClubCollapseToNearestRenewal() {
        let store = makeStore()
        store.identities = [identity(id: identityA, name: "A")]
        let nearID = UUID()
        let farID = UUID()
        store.memberships = [
            membership(id: farID, identityID: identityA, fc: "STELLARIS FC", renewalOn: day(2026, 12, 1)),
            membership(id: nearID, identityID: identityA, fc: "STELLARIS FC", renewalOn: day(2026, 8, 10)),
        ]

        let groups = store.groupedByFanClub(sortedBy: .renewalSoon, winCounts: [:])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.count, 1)
        XCTAssertEqual(groups[0].rows[0].membership?.id, nearID)
    }

    // MARK: - Helpers

    private func makeStore() -> IdentityStore {
        IdentityStore(now: { [today] in today })
    }

    private func identity(id: UUID, name: String, joinedOn: Date? = nil) -> Identity {
        Identity(
            id: id,
            displayName: name,
            relation: .self,
            colorHex: "#111111",
            joinedOn: joinedOn,
            updatedAt: today
        )
    }

    private func membership(
        id: UUID,
        identityID: UUID,
        fc: String,
        renewalOn: Date?,
        rank: String? = nil,
        feeYen: Int? = nil
    ) -> Membership {
        Membership(
            id: id,
            identityID: identityID,
            fanClubNameRaw: fc,
            rank: rank,
            renewalOn: renewalOn,
            feeYen: feeYen
        )
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }
}
