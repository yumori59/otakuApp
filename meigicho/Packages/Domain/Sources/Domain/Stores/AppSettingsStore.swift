import Foundation

/// アプリ表示名などの端末側設定。
///
/// 旧 `AppDataStore.appDisplayName` の受け皿。
/// NOTE(T1b): `GET/PATCH /v1/me` に接続する `ProfileStore` を T1b が新設したら、
/// `appDisplayName` は `UserProfile.appDisplayName` に統合してこのストアは畳む。
@MainActor
@Observable
public final class AppSettingsStore {
    public var appDisplayName: String?

    public init(appDisplayName: String? = nil) {
        self.appDisplayName = appDisplayName
    }

    public func setAppDisplayName(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        appDisplayName = trimmed.isEmpty ? nil : trimmed
    }
}
