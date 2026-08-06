import Foundation
import DesignSystem

/// 広告ユニット ID（`ADMOB_APP_ID`）が未設定（空文字）のときは SDK を初期化せず
/// `DisabledAdRenderer` を返す（F1-6 / N6 / AC-AD-36）。
/// 既存パターン踏襲: `App/Purchases/PurchasesServiceFactory.swift`。
enum AdRendererFactory {
    @MainActor
    static func make() -> any AdRenderer {
        #if canImport(GoogleMobileAds)
        let appID = (Bundle.main.object(forInfoDictionaryKey: "ADMOB_APP_ID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !appID.isEmpty {
            return GoogleMobileAdsRenderer(appID: appID)
        }
        #endif
        return DisabledAdRenderer()
    }
}
