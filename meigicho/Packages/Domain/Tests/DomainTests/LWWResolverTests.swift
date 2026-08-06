import XCTest
@testable import Domain

final class LWWResolverTests: XCTestCase {
    func testRemoteNewerTakesRemote() {
        let local = Date(timeIntervalSince1970: 100)
        let remote = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(
            LWWResolver.resolve(localUpdatedAt: local, remoteUpdatedAt: remote, remoteDeletedAt: nil),
            .takeRemote
        )
    }

    func testRemoteNewerDeletedDeletesLocal() {
        let local = Date(timeIntervalSince1970: 100)
        let remote = Date(timeIntervalSince1970: 200)
        let deleted = Date(timeIntervalSince1970: 200)
        XCTAssertEqual(
            LWWResolver.resolve(localUpdatedAt: local, remoteUpdatedAt: remote, remoteDeletedAt: deleted),
            .deleteLocal
        )
    }

    func testLocalNewerOrEqualKeepsLocal() {
        let t = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(
            LWWResolver.resolve(localUpdatedAt: t, remoteUpdatedAt: t, remoteDeletedAt: nil),
            .keepLocal
        )
        XCTAssertEqual(
            LWWResolver.resolve(
                localUpdatedAt: Date(timeIntervalSince1970: 200),
                remoteUpdatedAt: Date(timeIntervalSince1970: 100),
                remoteDeletedAt: nil
            ),
            .keepLocal
        )
    }
}
