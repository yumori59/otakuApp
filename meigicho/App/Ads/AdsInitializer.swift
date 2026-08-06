#if canImport(GoogleMobileAds)
import GoogleMobileAds

/// Google Mobile Ads SDK の初期化。起動 TTI をブロックしないよう
/// `Task.detached(priority: .utility)` で非同期化する（F1-2 / `docs/09-roadmap.md` T7 のリスク対応）。
///
/// 全リクエストを非パーソナライズ広告（NPA）固定にする（F1-4 / `docs/08-compliance-risk.md` §2.8）。
/// ATT プロンプト・UMP 同意画面は要求しない（F1-5）。
enum AdsInitializer {
    static func start() {
        Task.detached(priority: .utility) {
            let mobileAds = GADMobileAds.sharedInstance()
            // Publisher Privacy Treatment を「非パーソナライズ」に固定する。
            // バナー個別リクエストの GADExtras（npa=1）と合わせた二重の担保（F1-4）。
            mobileAds.requestConfiguration.publisherPrivacyPersonalizationState = .disabled
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                mobileAds.start { _ in
                    continuation.resume()
                }
            }
        }
    }
}
#endif
