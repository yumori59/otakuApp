import XCTest
import Core
import Domain
@testable import Network

/// `contract-mapping.md` §4.7 / `api-contract-delta.md` §1〜§3 の DTO 契約。
final class ShareDTOTests: XCTestCase {
    private let decoder = JSONDecoder()
    private let tourID = UUID(uuidString: "018f3c2a-dddd-7c90-9d2a-000000000001")!

    private func encodedObject(_ request: CreateShareRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - AC-SH-01-T: identity_summary は scope_id / permission のキーを作らない

    func testIdentitySummaryRequestOmitsScopeIDAndPermissionKeys() throws {
        let object = try encodedObject(
            CreateShareRequest(
                selection: .identitySummary,
                maskMemberNo: true,
                sharedWithAccountIDs: ["ACC-3F9A21"]
            )
        )
        XCTAssertEqual(object["scope_type"] as? String, "identity_summary")
        // **キーごと存在しない**（null を送るのでもない）。送ると 400
        XCTAssertNil(object.index(forKey: "scope_id"))
        XCTAssertNil(object.index(forKey: "permission"))
        XCTAssertEqual(Set(object.keys), ["scope_type", "mask_member_no", "shared_with_account_ids"])
    }

    // MARK: - AC-SH-04-T: permission は read / write のみ

    func testTourRequestSendsChosenPermission() throws {
        let read = try encodedObject(
            CreateShareRequest(
                selection: .tour(tourID, permission: .read),
                maskMemberNo: true,
                sharedWithAccountIDs: ["ACC-3F9A21"]
            )
        )
        XCTAssertEqual(read["scope_type"] as? String, "tour")
        XCTAssertEqual(read["scope_id"] as? String, "018f3c2a-dddd-7c90-9d2a-000000000001")
        XCTAssertEqual(read["permission"] as? String, "read")
        XCTAssertEqual(read["shared_with_account_ids"] as? [String], ["ACC-3F9A21"])

        let write = try encodedObject(
            CreateShareRequest(
                selection: .tour(tourID, permission: .write),
                maskMemberNo: false,
                sharedWithAccountIDs: ["ACC-3F9A21", "ACC-9F8E7D"]
            )
        )
        XCTAssertEqual(write["permission"] as? String, "write")
        XCTAssertEqual(write["mask_member_no"] as? Bool, false)
    }

    /// UI から未知値を作れないこと（enum なので `"admin"` などを生成する経路が無い）。
    func testPermissionRawValuesAreOnlyReadAndWrite() {
        XCTAssertEqual(Set(["read", "write"]), Set([SharePermission.read, .write].map(\.rawValue)))
        XCTAssertNil(SharePermission(rawValue: "admin"))
    }

    /// `expires_at` は送らない（サーバー既定の +30 日に任せる）。
    func testRequestDoesNotSendExpiresAt() throws {
        let object = try encodedObject(
            CreateShareRequest(
                selection: .tour(tourID, permission: .read),
                maskMemberNo: true,
                sharedWithAccountIDs: ["ACC-3F9A21"]
            )
        )
        XCTAssertNil(object.index(forKey: "expires_at"))
        XCTAssertNil(object.index(forKey: "id"))
    }

    // MARK: - AC-SH-03-T: `GET /v1/shares` の型は token / url を持てない

    func testShareResponseHasNoTokenOrURLFields() throws {
        // サーバーが誤って token を返しても、型として受け取らない
        let json = """
        {
          "id": "018f3c2a-1111-7c90-9d2a-000000000001",
          "scope_type": "tour",
          "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
          "scope_name": "STELLARIS LIVE TOUR 2026",
          "permission": "write",
          "mask_member_no": true,
          "recipients": [
            { "account_id": "ACC-3F9A21", "display_name": "ゆう",
              "invited_at": "2026-08-07T00:00:00.000Z", "last_viewed_at": null }
          ],
          "expires_at": "2026-08-31T00:00:00.000Z",
          "revoked_at": null,
          "view_count": 3,
          "last_viewed_at": "2026-08-02T10:00:00.000Z",
          "edit_count": 2,
          "last_edited_at": "2026-08-02T11:30:00.000Z",
          "created_at": "2026-08-01T00:00:00.000Z",
          "is_active": true,
          "token": "should-be-ignored",
          "url": "https://example.invalid/s/should-be-ignored"
        }
        """
        let response = try decoder.decode(ShareResponse.self, from: Data(json.utf8))
        let fields = Mirror(reflecting: response).children.compactMap(\.label)
        XCTAssertFalse(fields.contains("token"))
        XCTAssertFalse(fields.contains("url"))
    }

    // MARK: - 一覧のデコード（recipients / edit_count / last_edited_at の追従 = IOS-2）

    func testShareResponseDecodesAllFieldsIncludingRecipientsAndEditCounts() throws {
        let json = """
        {
          "items": [{
            "id": "018f3c2a-1111-7c90-9d2a-000000000001",
            "scope_type": "tour",
            "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
            "scope_name": "STELLARIS LIVE TOUR 2026",
            "permission": "write",
            "mask_member_no": true,
            "recipients": [
              { "account_id": "ACC-3F9A21", "display_name": "ゆう",
                "invited_at": "2026-08-07T00:00:00.000Z",
                "last_viewed_at": "2026-08-07T09:00:00.000Z" },
              { "account_id": "ACC-9F8E7D", "display_name": null,
                "invited_at": "2026-08-07T00:00:00.000Z", "last_viewed_at": null }
            ],
            "expires_at": "2026-08-31T00:00:00.000Z",
            "revoked_at": null,
            "view_count": 3,
            "last_viewed_at": "2026-08-02T10:00:00.000Z",
            "edit_count": 2,
            "last_edited_at": "2026-08-02T11:30:00.000Z",
            "created_at": "2026-08-01T00:00:00.000Z",
            "is_active": true
          }]
        }
        """
        let list = try decoder.decode(ShareListResponse.self, from: Data(json.utf8))
        let link = try XCTUnwrap(list.items.first).toDomain()

        XCTAssertEqual(link.id, UUID(uuidString: "018f3c2a-1111-7c90-9d2a-000000000001"))
        XCTAssertEqual(link.scopeType, .tour)
        XCTAssertEqual(link.scopeID, tourID)
        XCTAssertEqual(link.scopeName, "STELLARIS LIVE TOUR 2026")
        XCTAssertEqual(link.permission, .write)
        XCTAssertTrue(link.maskMemberNo)
        XCTAssertEqual(link.recipients.map(\.accountID), ["ACC-3F9A21", "ACC-9F8E7D"])
        XCTAssertEqual(link.recipients[0].displayName, "ゆう")
        XCTAssertNil(link.recipients[1].displayName)
        XCTAssertNotNil(link.recipients[0].lastViewedAt)
        XCTAssertNil(link.recipients[1].lastViewedAt)
        // `hidden_at` は来ない（Q3）。Domain の `ShareRecipient` にそもそもフィールドが無い
        XCTAssertEqual(link.expiresAt, APIDateFormat.dateTime(from: "2026-08-31T00:00:00.000Z"))
        XCTAssertNil(link.revokedAt)
        XCTAssertEqual(link.viewCount, 3)
        XCTAssertEqual(link.editCount, 2)
        XCTAssertEqual(link.lastEditedAt, APIDateFormat.dateTime(from: "2026-08-02T11:30:00.000Z"))
        XCTAssertTrue(link.isActive)
    }

    func testIdentitySummaryResponseDecodesWithNullScopeID() throws {
        let json = """
        {
          "id": "018f3c2a-1111-7c90-9d2a-000000000002",
          "scope_type": "identity_summary",
          "scope_id": null,
          "scope_name": null,
          "permission": "read",
          "mask_member_no": true,
          "recipients": [],
          "expires_at": null,
          "revoked_at": "2026-08-03T00:00:00.000Z",
          "view_count": 0,
          "last_viewed_at": null,
          "edit_count": 0,
          "last_edited_at": null,
          "created_at": "2026-08-01T00:00:00.000Z",
          "is_active": false
        }
        """
        let link = try decoder.decode(ShareResponse.self, from: Data(json.utf8)).toDomain()
        XCTAssertEqual(link.scopeType, .identitySummary)
        XCTAssertNil(link.scopeID)
        XCTAssertNil(link.expiresAt)
        XCTAssertFalse(link.isActive)
        XCTAssertTrue(link.recipients.isEmpty)
    }

    /// BE-2 の iOS 版: 未知の `permission` を黙って `read` に落とさない。
    func testUnknownPermissionFailsInsteadOfFallingBackToRead() {
        let json = """
        {
          "id": "018f3c2a-1111-7c90-9d2a-000000000001",
          "scope_type": "tour",
          "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
          "scope_name": null,
          "permission": "admin",
          "mask_member_no": true,
          "recipients": [],
          "expires_at": null,
          "revoked_at": null,
          "view_count": 0,
          "last_viewed_at": null,
          "edit_count": 0,
          "last_edited_at": null,
          "created_at": "2026-08-01T00:00:00.000Z",
          "is_active": true
        }
        """
        XCTAssertThrowsError(try decoder.decode(ShareResponse.self, from: Data(json.utf8)))
    }

    // MARK: - 発行レスポンス（token / url はここだけ）

    func testCreateShareResponseCarriesTokenAndURLAndRecipients() throws {
        let json = """
        {
          "id": "018f3c2a-1111-7c90-9d2a-000000000001",
          "token": "abcdef0123456789",
          "url": "meigicho://share/abcdef0123456789",
          "scope_type": "tour",
          "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
          "permission": "write",
          "mask_member_no": true,
          "recipients": [
            { "account_id": "ACC-3F9A21", "display_name": "ゆう",
              "invited_at": "2026-08-07T00:00:00.000Z", "last_viewed_at": null }
          ],
          "expires_at": "2026-08-31T00:00:00.000Z",
          "created_at": "2026-08-01T00:00:00.000Z"
        }
        """
        let issued = try decoder.decode(CreateShareResponse.self, from: Data(json.utf8)).toDomain()

        XCTAssertEqual(issued.token, "abcdef0123456789")
        // `url` は `meigicho://` カスタムスキーム（`https://.../s/*` は廃止）
        XCTAssertEqual(issued.url, "meigicho://share/abcdef0123456789")
        XCTAssertEqual(issued.link.permission, .write)
        XCTAssertEqual(issued.link.scopeID, tourID)
        XCTAssertEqual(issued.link.recipients.map(\.accountID), ["ACC-3F9A21"])
        // 201 は返さないキー。発行直後として自明な値で埋める
        XCTAssertEqual(issued.link.viewCount, 0)
        XCTAssertEqual(issued.link.editCount, 0)
        XCTAssertTrue(issued.link.isActive)
        XCTAssertNil(issued.link.revokedAt)
    }

    // MARK: - 招待の追加・削除（`api-contract-delta.md` §3）

    func testAddRecipientsRequestEncodesAccountIDs() throws {
        let data = try JSONEncoder().encode(AddRecipientsRequest(accountIDs: ["ACC-1A2B3C"]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["account_ids"] as? [String], ["ACC-1A2B3C"])
    }

    /// レスポンスは**追加後の全件**（差分ではない）。
    func testRecipientsResponseDecodesAllEntries() throws {
        let json = """
        { "recipients": [
          { "account_id": "ACC-1A2B3C", "display_name": null,
            "invited_at": "2026-08-07T00:00:00.000Z", "last_viewed_at": null }
        ] }
        """
        let response = try decoder.decode(RecipientsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.recipients.map { $0.toDomain().accountID }, ["ACC-1A2B3C"])
    }

    // MARK: - エンドポイント

    func testShareEndpointsAreVersioned() throws {
        let baseURL = URL(string: "http://localhost:8080")!
        let list = try Endpoint.versioned(.get, "/shares").urlRequest(baseURL: baseURL, extraHeaders: [:])
        XCTAssertEqual(list.url?.absoluteString, "http://localhost:8080/v1/shares")

        let id = UUID(uuidString: "018f3c2a-1111-7c90-9d2a-000000000001")!
        let delete = try Endpoint
            .versioned(.delete, "/shares/\(id.uuidString.lowercased())")
            .urlRequest(baseURL: baseURL, extraHeaders: [:])
        XCTAssertEqual(
            delete.url?.absoluteString,
            "http://localhost:8080/v1/shares/018f3c2a-1111-7c90-9d2a-000000000001"
        )
        XCTAssertEqual(delete.httpMethod, "DELETE")

        let addRecipients = try Endpoint
            .versioned(.post, "/shares/\(id.uuidString.lowercased())/recipients")
            .urlRequest(baseURL: baseURL, extraHeaders: [:])
        XCTAssertEqual(
            addRecipients.url?.absoluteString,
            "http://localhost:8080/v1/shares/018f3c2a-1111-7c90-9d2a-000000000001/recipients"
        )

        let removeRecipient = try Endpoint
            .versioned(.delete, "/shares/\(id.uuidString.lowercased())/recipients/ACC-1A2B3C")
            .urlRequest(baseURL: baseURL, extraHeaders: [:])
        XCTAssertEqual(
            removeRecipient.url?.absoluteString,
            "http://localhost:8080/v1/shares/018f3c2a-1111-7c90-9d2a-000000000001/recipients/ACC-1A2B3C"
        )
        XCTAssertEqual(removeRecipient.httpMethod, "DELETE")
    }
}
