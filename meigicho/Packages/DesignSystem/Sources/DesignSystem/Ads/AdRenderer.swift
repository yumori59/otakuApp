import SwiftUI

/// 広告 SDK の描画を抽象化する protocol（`docs/plans/admob-integration/plan.md` §4 D4）。
///
/// `Features` は本 protocol と `AdSlot` のみを参照し、`GoogleMobileAds` 等の SDK を直接
/// import しない（IOS-5）。実装（`GoogleMobileAdsRenderer` / `DisabledAdRenderer`）は
/// `App/Ads/` に置き、Composition Root（`App/AppEnvironment.swift`）が
/// `@Environment(\.adRenderer)` 経由で注入する。
@MainActor
public protocol AdRenderer: Sendable {
    /// インライン・アダプティブバナーを描画する（F2-2 / F2-4 / F2-5）。
    ///
    /// - `adUnitID` が空 / 幅が 0 など、そもそも要求できない場合は `nil` を返す（呼び出し側は高さ 0 扱い）
    /// - 要求はできたが**配信されなかった**（no-fill・ネットワーク失敗）場合は `onFailure` を呼ぶ。
    ///   呼び出し側は枠ごと畳んで空枠を残さない（F4-4 / F5-6 / `docs/07:448`）
    func bannerView(
        adUnitID: String,
        width: CGFloat,
        onFailure: @escaping @MainActor () -> Void
    ) -> AnyView?

    /// ネイティブ広告（カスタムレイアウト、F2-1 / F2-3）。
    ///
    /// - `adUnitID` が空の場合は `nil` を返す（呼び出し側は高さ 0 扱い）
    /// - 要求はできたが**配信されなかった**（no-fill・ネットワーク失敗）場合は `onFailure` を呼ぶ。
    ///   呼び出し側は枠ごと畳んで空枠を残さない（F4-4 / F5-6 / `docs/07:448`）
    func nativeAdView(
        adUnitID: String,
        onFailure: @escaping @MainActor () -> Void
    ) -> AnyView?

    // MARK: - Stage 2（本パッケージの対象外。リワード広告）

    /// リワード動画広告のロード（F2-6 / F6）。Stage 1 では未実装。
    func loadRewardedAd(adUnitID: String) async throws

    /// ロード済みのリワード広告を表示し、視聴完了なら `true` を返す。Stage 1 では未実装。
    func presentRewardedAd() async throws -> Bool
}

/// `AdRenderer` の Stage 1 実装が対応しないメソッドを呼んだ場合のエラー。
public enum AdRendererError: Error, Sendable {
    /// ネイティブ広告・リワード広告は Stage 2（別タスク）で実装する
    case notImplemented
}

/// `@Environment(\.adRenderer)` で `(any AdRenderer)?` を取得するための Environment key
/// （`docs/plans/admob-integration/plan.md` §4 D4）。
/// 既定値は `nil`。未注入（プレビュー・単体テスト等）では `AdSlot` は何も描画しない。
private struct AdRendererKey: EnvironmentKey {
    static let defaultValue: (any AdRenderer)? = nil
}

extension EnvironmentValues {
    public var adRenderer: (any AdRenderer)? {
        get { self[AdRendererKey.self] }
        set { self[AdRendererKey.self] = newValue }
    }
}
