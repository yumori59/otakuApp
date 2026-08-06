import XCTest
import Core
import Domain
@testable import Network

/// `contract-mapping.md` §4.3 の DTO 契約。
final class IdentityDTOTests: XCTestCase {
    private let decoder = JSONDecoder()

    /// AC-ID-01-T: `IdentityResponse` の 11 フィールドが 1 つも欠けずにマッピングされる。
    func testIdentityResponseDecodesAllFieldsAndMapsToDomain() throws {
        let json = """
        {
          "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
          "display_name": "推し太郎",
          "relation": "friend",
          "color": "#FF00AA",
          "joined_on": "2026-04-01",
          "note": "備考テキスト",
          "history_visible": true,
          "sort_order": 3,
          "created_at": "2026-04-01T00:00:00.000Z",
          "updated_at": "2026-07-01T12:34:56.000Z",
          "deleted_at": null
        }
        """
        let response = try decoder.decode(IdentityResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.id, UUID(uuidString: "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f"))
        XCTAssertEqual(response.displayName, "推し太郎")
        XCTAssertEqual(response.relation, "friend")
        XCTAssertEqual(response.color, "#FF00AA")
        XCTAssertEqual(response.joinedOn, "2026-04-01")
        XCTAssertEqual(response.note, "備考テキスト")
        XCTAssertTrue(response.historyVisible)
        XCTAssertEqual(response.sortOrder, 3)
        XCTAssertEqual(response.createdAt, "2026-04-01T00:00:00.000Z")
        XCTAssertEqual(response.updatedAt, "2026-07-01T12:34:56.000Z")
        XCTAssertNil(response.deletedAt)

        let identity = response.toDomain()
        XCTAssertEqual(identity.id, response.id)
        XCTAssertEqual(identity.displayName, "推し太郎")
        XCTAssertEqual(identity.relation, .friend)
        XCTAssertEqual(identity.colorHex, "#FF00AA")
        XCTAssertEqual(identity.joinedOn, APIDateFormat.dateOnly(from: "2026-04-01"))
        XCTAssertTrue(identity.historyVisible)
        XCTAssertEqual(identity.note, "備考テキスト")
        XCTAssertEqual(identity.sortOrder, 3)
        XCTAssertEqual(identity.updatedAt, APIDateFormat.dateTime(from: "2026-07-01T12:34:56.000Z"))
    }

    /// null になりうる任意フィールド（`joined_on` / `note`）でも失敗しない。未知の `relation` は `.other`。
    func testIdentityResponseHandlesNullableFieldsAndUnknownRelation() throws {
        let json = """
        {
          "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e70",
          "display_name": "名義B",
          "relation": "band_member",
          "color": "#000000",
          "joined_on": null,
          "note": null,
          "history_visible": false,
          "sort_order": 0,
          "created_at": "2026-04-01T00:00:00Z",
          "updated_at": "2026-04-01T00:00:00Z",
          "deleted_at": null
        }
        """
        let response = try decoder.decode(IdentityResponse.self, from: Data(json.utf8))
        let identity = response.toDomain()
        XCTAssertNil(identity.joinedOn)
        XCTAssertEqual(identity.note, "")
        // BE-2 の iOS 版: 未知の relation で失敗しない
        XCTAssertEqual(identity.relation, .other)
    }

    /// AC-ID-02-T: 既定の `Identity`（`history_visible = false` / Q9）から作った `CreateIdentityRequest`
    func testCreateRequestDefaultsHistoryVisibleToFalse() throws {
        let identity = Identity(displayName: "新規名義", relation: .other, colorHex: "#123456")
        XCTAssertFalse(identity.historyVisible)

        let request = identity.toCreateRequest()
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["history_visible"] as? Bool, false)
        XCTAssertEqual(object["id"] as? String, identity.id.uuidString)
        XCTAssertEqual(object["relation"] as? String, "other")
        XCTAssertNil(object["note"]) // 空文字は null として送る
    }

    /// 空文字の `note` だけ null になる（空白のみはそのまま送る）
    func testCreateRequestOmitsEmptyNoteOnly() throws {
        let withWhitespace = Identity(displayName: "A", relation: .self, colorHex: "#000000", note: "  ")
        XCTAssertEqual(withWhitespace.toCreateRequest().note, "  ")

        let empty = Identity(displayName: "A", relation: .self, colorHex: "#000000", note: "")
        XCTAssertNil(empty.toCreateRequest().note)
    }

    /// `Patchable.unchanged` はキーごと省略される（`contract-mapping.md` §1.2）
    func testUpdateRequestOnlyEncodesChangedKeys() throws {
        var patch = IdentityPatch()
        patch.colorHex = .set("#ABCDEF")
        let data = try JSONEncoder().encode(patch.toRequest())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.count, 1)
        XCTAssertEqual(object["color"] as? String, "#ABCDEF")
    }

    /// `note` を `.set(nil)` にすると明示的な `null` が出力される
    func testUpdateRequestNoteClearSendsNull() throws {
        var patch = IdentityPatch()
        patch.note = .set(nil)
        let data = try JSONEncoder().encode(patch.toRequest())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["note"] is NSNull)
    }
}
