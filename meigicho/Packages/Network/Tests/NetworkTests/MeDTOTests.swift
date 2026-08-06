import XCTest
import Core
import Domain
@testable import Network

/// `GET/PATCH /v1/me` の DTO 契約（`contract-mapping.md` §4.2 / AC-ME-03・AC-ME-04）。
final class MeDTOTests: XCTestCase {
    private let sample = """
    {
      "user": {
        "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
        "email": "abc@privaterelay.appleid.com",
        "auth_providers": ["apple", "email"],
        "created_at": "2026-08-01T00:00:00.000Z"
      },
      "profile": {
        "account_id": "ACC-3F9A21",
        "display_name": null,
        "username": "yuya",
        "app_display_name": "参戦名義帳",
        "theme_color": "#0017C1",
        "locale": "ja_JP",
        "timezone": "Asia/Tokyo",
        "onboarded_at": null,
        "created_at": "2026-08-01T00:00:00.000Z",
        "updated_at": "2026-08-01T00:00:00.000Z"
      },
      "entitlement": {
        "plan": "free",
        "expires_at": null,
        "in_grace_period": false,
        "bonus_identity_slots": 0,
        "bonus_expires_at": null,
        "identity_limit": 3,
        "share_limit": 1
      }
    }
    """

    func testMeResponseMapsEveryField() throws {
        let snapshot = try JSONDecoder().decode(MeResponse.self, from: Data(sample.utf8)).toDomain()

        XCTAssertEqual(snapshot.profile.userID, UUID(uuidString: "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f"))
        XCTAssertEqual(snapshot.profile.accountID, "ACC-3F9A21")
        XCTAssertNil(snapshot.profile.displayName)
        XCTAssertEqual(snapshot.profile.username, "yuya")
        XCTAssertEqual(snapshot.profile.appDisplayName, "参戦名義帳")
        XCTAssertEqual(snapshot.profile.themeColor, "#0017C1")
        XCTAssertEqual(snapshot.profile.locale, "ja_JP")
        XCTAssertEqual(snapshot.profile.timezone, "Asia/Tokyo")
        XCTAssertNil(snapshot.profile.onboardedAt)
        XCTAssertEqual(snapshot.profile.email, "abc@privaterelay.appleid.com")
        XCTAssertEqual(snapshot.profile.authProviders, ["apple", "email"])
        XCTAssertTrue(snapshot.profile.hasPasswordLogin)

        XCTAssertEqual(snapshot.entitlement.plan, .free)
        XCTAssertNil(snapshot.entitlement.expiresAt)
        XCTAssertFalse(snapshot.entitlement.inGracePeriod)
        XCTAssertEqual(snapshot.entitlement.bonusIdentitySlots, 0)
        XCTAssertEqual(snapshot.entitlement.identityLimit, 3)
        XCTAssertEqual(snapshot.entitlement.shareLimit, 1)
    }

    /// `plus` の `identity_limit` / `share_limit` は `null`（= 無制限）
    func testPlusEntitlementNullLimitsMeanUnlimited() throws {
        let json = sample
            .replacingOccurrences(of: "\"plan\": \"free\"", with: "\"plan\": \"plus\"")
            .replacingOccurrences(of: "\"identity_limit\": 3", with: "\"identity_limit\": null")
            .replacingOccurrences(of: "\"share_limit\": 1", with: "\"share_limit\": null")
        let snapshot = try JSONDecoder().decode(MeResponse.self, from: Data(json.utf8)).toDomain()

        XCTAssertEqual(snapshot.entitlement.plan, .plus)
        XCTAssertNil(snapshot.entitlement.identityLimit)
        XCTAssertNil(snapshot.entitlement.shareLimit)
    }

    /// AC-ME-04: 未知の `auth_providers` が来てもデコードに失敗しない（`[String]` のまま持つ）
    func testUnknownAuthProviderDoesNotFailDecoding() throws {
        let json = sample.replacingOccurrences(of: "[\"apple\", \"email\"]", with: "[\"apple\", \"line\"]")
        let snapshot = try JSONDecoder().decode(MeResponse.self, from: Data(json.utf8)).toDomain()

        XCTAssertEqual(snapshot.profile.authProviders, ["apple", "line"])
        XCTAssertFalse(snapshot.profile.hasPasswordLogin)
    }

    /// 未知の plan でプロフィール取得ごと落とさない（BE-2 の iOS 版）
    func testUnknownPlanFallsBackToFree() throws {
        let json = sample.replacingOccurrences(of: "\"plan\": \"free\"", with: "\"plan\": \"enterprise\"")
        let snapshot = try JSONDecoder().decode(MeResponse.self, from: Data(json.utf8)).toDomain()
        XCTAssertEqual(snapshot.entitlement.plan, .free)
    }

    /// `email` が null（Apple の非公開リレー未提供など）でも失敗しない
    func testNullEmailDecodes() throws {
        let json = sample.replacingOccurrences(of: "\"email\": \"abc@privaterelay.appleid.com\"", with: "\"email\": null")
        let snapshot = try JSONDecoder().decode(MeResponse.self, from: Data(json.utf8)).toDomain()
        XCTAssertNil(snapshot.profile.email)
    }

    func testOnboardedAtIsParsedWithAndWithoutFractionalSeconds() throws {
        let withFraction = sample.replacingOccurrences(of: "\"onboarded_at\": null", with: "\"onboarded_at\": \"2026-08-01T09:00:00.000Z\"")
        let a = try JSONDecoder().decode(MeResponse.self, from: Data(withFraction.utf8)).toDomain()
        XCTAssertEqual(a.profile.onboardedAt, APIDateFormat.dateTime(from: "2026-08-01T09:00:00.000Z"))

        let withoutFraction = sample.replacingOccurrences(of: "\"onboarded_at\": null", with: "\"onboarded_at\": \"2026-08-01T09:00:00Z\"")
        let b = try JSONDecoder().decode(MeResponse.self, from: Data(withoutFraction.utf8)).toDomain()
        XCTAssertEqual(b.profile.onboardedAt, a.profile.onboardedAt)
    }

    // MARK: - PATCH

    /// AC-ME-03: **`account_id` / `plan` / `id` を送らない**（`forbidNonWhitelisted` で 400）
    func testUpdateRequestNeverContainsReadOnlyKeys() throws {
        var patch = ProfilePatch()
        patch.username = .set("yuya")
        patch.themeColor = .set("#FF00AA")

        let object = try encode(patch)
        XCTAssertNil(object["account_id"])
        XCTAssertNil(object["plan"])
        XCTAssertNil(object["id"])
        XCTAssertEqual(object["username"] as? String, "yuya")
        XCTAssertEqual(object["theme_color"] as? String, "#FF00AA")
        // 触っていないキーは**送らない**（送られたキーのみ更新される契約 — §1.2）
        XCTAssertEqual(object.count, 2)
    }

    /// `.unchanged` は省略、`.set(nil)` は明示的な `null`
    func testUnchangedIsOmittedAndSetNilIsExplicitNull() throws {
        var patch = ProfilePatch()
        patch.username = .set(nil)

        let data = try JSONEncoder().encode(UpdateMeRequest(patch: patch))
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(raw, #"{"username":null}"#)
    }

    func testEmptyPatchEncodesToEmptyObject() throws {
        let data = try JSONEncoder().encode(UpdateMeRequest(patch: ProfilePatch()))
        XCTAssertEqual(String(data: data, encoding: .utf8), "{}")
    }

    /// `onboarded_at` は ISO8601 UTC ミリ秒で送る（§2.1）
    func testOnboardedAtIsSentAsISO8601() throws {
        var patch = ProfilePatch()
        patch.onboardedAt = .set(Date(timeIntervalSince1970: 1_800_000_000))

        let object = try encode(patch)
        let sent = try XCTUnwrap(object["onboarded_at"] as? String)
        XCTAssertEqual(APIDateFormat.dateTime(from: sent), Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func encode(_ patch: ProfilePatch) throws -> [String: Any] {
        let data = try JSONEncoder().encode(UpdateMeRequest(patch: patch))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
