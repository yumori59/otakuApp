import XCTest
@testable import Network
import Domain

final class SyncDTOTests: XCTestCase {
    func testDecodesPullResponse() throws {
        let id = "018f3c2a-aaaa-7c90-9d2a-000000000001"
        let json = """
        {
          "changes": {
            "identities": [{
              "id": "\(id)",
              "display_name": "自分",
              "updated_at": "2026-07-31T10:00:00.000Z",
              "deleted_at": null
            }],
            "memberships": [],
            "tours": [],
            "events": [],
            "applications": [],
            "application_companions": []
          },
          "next_cursor": "2026-07-31T10:00:00.000Z",
          "has_more": false
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(SyncPullResponseDTO.self, from: json).toDomain()
        XCTAssertEqual(result.hasMore, false)
        XCTAssertEqual(result.changes[.identities]?.count, 1)
        XCTAssertEqual(result.changes[.identities]?[0]["display_name"]?.stringValue, "自分")
        XCTAssertNotNil(result.nextCursor)
    }

    func testDecodesPushResponse() throws {
        let id = "018f3c2a-aaaa-7c90-9d2a-000000000001"
        let json = """
        {
          "accepted": ["\(id)"],
          "rejected": [{
            "id": "018f3c2a-bbbb-7c90-9d2a-000000000002",
            "code": "SYNC_LWW_REJECT",
            "message": "server copy is newer"
          }],
          "server_time": "2026-07-31T12:00:00.000Z"
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(SyncPushResponseDTO.self, from: json).toDomain()
        XCTAssertEqual(result.accepted.count, 1)
        XCTAssertEqual(result.rejected.first?.code, "SYNC_LWW_REJECT")
    }
}
