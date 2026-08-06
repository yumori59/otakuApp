import SwiftUI

/// 広告 SDK の描画を抽象化する protocol（`docs/plans/admob-integration/plan.md` §4 D4）。
///
/// **暫定配置に関する注記**: 設計上は `DesignSystem/Ads/AdRenderer.swift`（Wave2 T8）に置き、
/// `AdSlot` が `@Environment(\.adRenderer)` 経由で `(any AdRenderer)?` を参照する想定
/// （plan.md D4）。本タスク（Wave2 T9）は DesignSystem / Features に触れない制約のため、
/// T8 完了までの暫定として `App` 層に定義する。T8 実装時にこのファイルを
/// `DesignSystem/Ads/AdRenderer.swift` へ移設し、`GoogleMobileAdsRenderer` /
/// `DisabledAdRenderer` の準拠はそのまま残すこと（Environment 注入は Composition Root
/// である `App/AppEnvironment.swift` 側で行う）。
@MainActor
public protocol AdRenderer: Sendable {
    /// インライン・アダプティブバナーを描画する（F2-2 / F2-4 / F2-5）。
    /// ロードに失敗した場合や `adUnitID` が空の場合は `nil` を返し、呼び出し側は高さ 0 として扱う（E3）。
    func bannerView(adUnitID: String, width: CGFloat) -> AnyView?

    // MARK: - Stage 2（本タスクの対象外。ネイティブ広告・リワード広告）

    /// ネイティブ広告（カスタムレイアウト、F2-1 / F2-3）。Stage 1 では常に `nil`。
    func nativeAdView(adUnitID: String) -> AnyView?

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
