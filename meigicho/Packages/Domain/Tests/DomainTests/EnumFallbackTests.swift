import XCTest
@testable import Domain

/// AC-N-07-T: 未知の生値はフォールバックするが、フォールバックした事実が戻り値に現れる
final class EnumFallbackTests: XCTestCase {
    func testRelationKnownValues() {
        for raw in ["self", "family", "friend", "other"] {
            let decoded = Relation.decoded(raw)
            XCTAssertEqual(decoded.value.rawValue, raw)
            XCTAssertFalse(decoded.didFallback)
        }
    }

    func testRelationUnknownFallsBackToOtherAndReportsIt() {
        let decoded = Relation.decoded("colleague")
        XCTAssertEqual(decoded.value, .other)
        XCTAssertTrue(decoded.didFallback)
        XCTAssertEqual(decoded.rawValue, "colleague")
    }

    func testApplicationStatusKnownValues() {
        for raw in ["draft", "applied", "won", "lost", "cancelled"] {
            let decoded = ApplicationStatus.decoded(raw)
            XCTAssertEqual(decoded.value.rawValue, raw)
            XCTAssertFalse(decoded.didFallback)
        }
    }

    func testApplicationStatusUnknownFallsBackToAppliedAndReportsIt() {
        let decoded = ApplicationStatus.decoded("waitlisted")
        XCTAssertEqual(decoded.value, .applied)
        XCTAssertTrue(decoded.didFallback)
        XCTAssertEqual(decoded.rawValue, "waitlisted")
    }

    func testSharePermissionUnknownIsNotSilentlyDowngraded() {
        // BE-2 の iOS 版: 未知の permission を read に丸めない
        XCTAssertNil(SharePermission(rawValue: "admin"))
        XCTAssertEqual(SharePermission(rawValue: "read"), .read)
        XCTAssertEqual(SharePermission(rawValue: "write"), .write)
    }

    func testPlanAndShareScopeRawValuesMatchContract() {
        XCTAssertEqual(Plan.free.rawValue, "free")
        XCTAssertEqual(Plan.plus.rawValue, "plus")
        XCTAssertEqual(ShareScope.tour.rawValue, "tour")
        XCTAssertEqual(ShareScope.identitySummary.rawValue, "identity_summary")
    }
}
