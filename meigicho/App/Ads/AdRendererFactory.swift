import Foundation
import DesignSystem

/// 広告ユニット ID が 1 つも設定されていないときは SDK を初期化せず `DisabledAdRenderer` を返す
/// （F1-6 / N6 / AC-AD-36）。既存パターン踏襲: `App/Purchases/PurchasesServiceFactory.swift`。
///
/// 判定に `ADMOB_APP_ID`（`GADApplicationIdentifier`）は使わない。SDK はリンクされている時点で
/// 起動時に plist の値を検証し、空文字・キー欠落なら NSException でアプリを落とすため、
/// `ADMOB_APP_ID` は常に妥当な値（実 ID か Google 公式サンプル ID）が入っている前提になる。
enum AdRendererFactory {
    @MainActor
    static func make(hasConfiguredUnitIDs: Bool) -> any AdRenderer {
        #if canImport(GoogleMobileAds)
        let appID = (Bundle.main.object(forInfoDictionaryKey: "ADMOB_APP_ID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if hasConfiguredUnitIDs, !appID.isEmpty {
            return GoogleMobileAdsRenderer(appID: appID)
        }
        #endif
        return DisabledAdRenderer()
    }
}
