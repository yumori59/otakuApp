import XCTest
import Core
import Domain
@testable import Networking

/// AC-AV-30: `avatar_url` フィールドの 3 通りデコードと `toDomain()` で `URL?` への変換。
final class MeDTOAvatarTests: XCTestCase {
    private func meJSON(avatarURLValue: String) -> String {
        """
        {
          "user": {
            "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
            "email": "fan@example.com",
            "auth_providers": ["apple"],
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
            "avatar_url": \(avatarURLValue),
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
    }

    private func meJSONWithoutAvatarKey() -> String {
        """
        {
          "user": {
            "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
            "email": "fan@example.com",
            "auth_providers": ["apple"],
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
    }

    /// `avatar_url` が文字列 → `toDomain()` で `URL` に変換される
    func testAvatarURLStringDecodesAndMapsToDomain() throws {
        let urlString = "https://storage.googleapis.com/meigicho-prod-avatars/avatars/abc.jpg"
        let json = meJSON(avatarURLValue: #""\#(urlString)""#)
        let snapshot = try JSONDecoder().decode(MeResponse.self, from: Data(json.utf8)).toDomain()

        XCTAssertEqual(snapshot.profile.avatarURL, URL(string: urlString))
    }

    /// `avatar_url` が `null` → `avatarURL` は `nil`
    func testAvatarURLNullDecodesToNil() throws {
        let json = meJSON(avatarURLValue: "null")
        let snapshot = try JSONDecoder().decode(MeResponse.self, from: Data(json.utf8)).toDomain()

        XCTAssertNil(snapshot.profile.avatarURL)
    }

    /// `avatar_url` キーが欠落 → デコード成功かつ `avatarURL` は `nil`（Optional なのでキー欠落でもクラッシュしない）
    func testAvatarURLKeyAbsentDecodesSuccessfully() throws {
        let json = meJSONWithoutAvatarKey()
        let snapshot = try JSONDecoder().decode(MeResponse.self, from: Data(json.utf8)).toDomain()

        XCTAssertNil(snapshot.profile.avatarURL)
    }
}
