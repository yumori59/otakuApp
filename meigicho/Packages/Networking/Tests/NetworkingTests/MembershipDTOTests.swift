import XCTest
import Core
import Domain
@testable import Networking

/// `contract-mapping.md` §4.4 の DTO 契約。
final class MembershipDTOTests: XCTestCase {
    private let decoder = JSONDecoder()

    /// AC-ID-03-T: `renewal_on` / `fee_yen` が null でも成功する
    func testMembershipResponseHandlesNullRenewalAndFee() throws {
        let json = """
        {
          "id": "018f3c2a-7b1e-7c90-9d2a-2222222222aa",
          "identity_id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
          "fan_club_name_raw": "STELLARIS OFFICIAL FAN CLUB",
          "member_no": "STL-04821",
          "rank": "プレミアム",
          "renewal_on": null,
          "fee_yen": null,
          "auto_renew": false,
          "note": null,
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": "2026-01-01T00:00:00Z",
          "deleted_at": null
        }
        """
        let response = try decoder.decode(MembershipResponse.self, from: Data(json.utf8))
        let membership = response.toDomain()
        XCTAssertNil(membership.renewalOn)
        XCTAssertNil(membership.feeYen)
        XCTAssertEqual(membership.memberNo, "STL-04821")
        XCTAssertEqual(membership.rank, "プレミアム")
        XCTAssertEqual(membership.note, "")
        XCTAssertFalse(membership.autoRenew)
        XCTAssertEqual(membership.identityID, UUID(uuidString: "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f"))
    }

    /// `renewal_on` / `fee_yen` が設定済みでも正しく変換される（往復）
    func testMembershipResponseMapsPresentRenewalAndFee() throws {
        let json = """
        {
          "id": "018f3c2a-7b1e-7c90-9d2a-2222222222bb",
          "identity_id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
          "fan_club_name_raw": "FC",
          "member_no": null,
          "rank": null,
          "renewal_on": "2026-09-15",
          "fee_yen": 4000,
          "auto_renew": true,
          "note": "メモ",
          "created_at": "2026-01-01T00:00:00Z",
          "updated_at": "2026-01-01T00:00:00Z",
          "deleted_at": null
        }
        """
        let membership = try decoder.decode(MembershipResponse.self, from: Data(json.utf8)).toDomain()
        XCTAssertEqual(membership.renewalOn, APIDateFormat.dateOnly(from: "2026-09-15"))
        XCTAssertEqual(membership.feeYen, 4000)
        XCTAssertTrue(membership.autoRenew)
        XCTAssertEqual(membership.note, "メモ")
    }

    /// AC-MN-10: `member_no` は全桁で送られる。`member_no_last4` / `member_no_cipher` は型として定義しない（送ると 400）
    func testCreateRequestSendsFullMemberNo() throws {
        let membership = Membership(identityID: UUID(), fanClubNameRaw: "FC", memberNo: "STL-04821")
        let data = try JSONEncoder().encode(membership.toCreateRequest())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["member_no"] as? String, "STL-04821")
        XCTAssertNil(object["member_no_last4"])
        XCTAssertNil(object["member_no_cipher"])
        XCTAssertEqual(object["auto_renew"] as? Bool, false)
    }

    /// `Patchable.unchanged` はキーごと省略される
    func testUpdateRequestOnlyEncodesChangedKeys() throws {
        var patch = MembershipPatch()
        patch.renewalOn = .set(nil)
        let data = try JSONEncoder().encode(patch.toRequest())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object.count, 1)
        XCTAssertTrue(object["renewal_on"] is NSNull)
    }
}
