import XCTest
@testable import Networking

final class HomeSummaryDTOTests: XCTestCase {
    func testDecodesSummaryResponse() throws {
        let json = """
        {
          "identity_count": 3,
          "renewals_within_30_days": 2,
          "pending_results": 4,
          "upcoming_renewals": [],
          "pending_applications": []
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(HomeSummaryResponse.self, from: json)
        let summary = response.toDomain()

        XCTAssertEqual(summary.identityCount, 3)
        XCTAssertEqual(summary.renewalsWithin30Days, 2)
        XCTAssertEqual(summary.pendingResults, 4)
    }
}
