import XCTest
@testable import Network

final class IdentityStatsDTOTests: XCTestCase {
    func testDecodesStatsResponse() throws {
        let id = "018f3c2a-aaaa-7c90-9d2a-000000000001"
        let json = """
        {
          "items": [{
            "identity_id": "\(id)",
            "application_count": 12,
            "won_count": 5,
            "lost_count": 4,
            "pending_count": 3,
            "win_rate_percent": 55.6
          }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(IdentityStatsResponse.self, from: json)
        let snapshot = response.toDomain()

        XCTAssertEqual(snapshot.items.count, 1)
        let item = snapshot.items[0]
        XCTAssertEqual(item.identityID.uuidString.lowercased(), id)
        XCTAssertEqual(item.applicationCount, 12)
        XCTAssertEqual(item.wonCount, 5)
        XCTAssertEqual(item.lostCount, 4)
        XCTAssertEqual(item.pendingCount, 3)
        XCTAssertEqual(item.winRatePercent, 55.6)
    }

    func testNullWinRatePercent() throws {
        let json = """
        {
          "items": [{
            "identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000001",
            "application_count": 0,
            "won_count": 0,
            "lost_count": 0,
            "pending_count": 0,
            "win_rate_percent": null
          }]
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(IdentityStatsResponse.self, from: json).toDomain().items[0]
        XCTAssertNil(item.winRatePercent)
    }
}
