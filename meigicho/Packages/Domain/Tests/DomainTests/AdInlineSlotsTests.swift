import XCTest
@testable import Domain

/// F2-3（5件目の後、以降10件ごと、1画面あたり2枚）と E13（5件未満は挿入しない）の検証。
final class AdInlineSlotsTests: XCTestCase {
    func testNoAdBelowFiveItems() {
        // E13: 0〜4 件では 1 枚も入らない（ゼロ件境界を含む）
        for count in 0...4 {
            XCTAssertEqual(AdInlineSlots.adPositions(itemCount: count), [], "\(count) 件で広告が入っている")
        }
    }

    func testFirstAdAfterFifthItem() {
        // 5 件ちょうどでリスト末尾（index 4 の行の後）に 1 枚
        XCTAssertEqual(AdInlineSlots.adPositions(itemCount: 5), [4])
        XCTAssertEqual(AdInlineSlots.adPositions(itemCount: 14), [4])
    }

    func testSecondAdAfterTenMoreItems() {
        // 15 件目が存在して初めて 2 枚目（index 14 の行の後）
        XCTAssertEqual(AdInlineSlots.adPositions(itemCount: 15), [4, 14])
        XCTAssertEqual(AdInlineSlots.adPositions(itemCount: 24), [4, 14])
    }

    func testCapsAtTwoPerScreen() {
        // 25 件以上あっても 3 枚目（index 24）は出さない（F2-3 上限 2 枚）
        XCTAssertEqual(AdInlineSlots.adPositions(itemCount: 25), [4, 14])
        XCTAssertEqual(AdInlineSlots.adPositions(itemCount: 100), [4, 14])
        XCTAssertLessThanOrEqual(AdInlineSlots.adPositions(itemCount: 100).count, AdInlineSlots.maxPerScreen)
    }

    func testShouldInsertAdMatchesPositions() {
        XCTAssertTrue(AdInlineSlots.shouldInsertAd(afterIndex: 4, itemCount: 20))
        XCTAssertTrue(AdInlineSlots.shouldInsertAd(afterIndex: 14, itemCount: 20))
        XCTAssertFalse(AdInlineSlots.shouldInsertAd(afterIndex: 5, itemCount: 20))
        XCTAssertFalse(AdInlineSlots.shouldInsertAd(afterIndex: 4, itemCount: 4))
    }
}
