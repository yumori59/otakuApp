import SwiftUI
import DesignSystem
import Domain

/// `AdPlacement` 1 面ぶんの広告枠。`Domain.AdsStore`（= `AdGatekeeper`）の判定と
/// `DesignSystem.AdSlot`（描画）を繋ぐ、Features 側の唯一の広告エントリポイント。
///
/// **`AdPlacement` に case が無い面（申込詳細・全フォーム・共有プレビュー・共有ボード）は
/// このビューを構築する引数自体が作れない**（F3 / `Domain/Ads/AdPlacement.swift`）。
///
/// 判定を `body` の中で毎回やり直さない理由:
/// `AdGatekeeper` は F4-3（同一面の連続表示禁止）を `lastShownPlacement == placement` で表すため、
/// インプレッションを記録した瞬間に同じ面の `shouldShow` は false に反転する。
/// `isVisible` を直に束ねると表示直後に枠が消えるので、**一度 true にしたらラッチする**。
/// ただしラッチは無条件ではない。表示中は `AdsStore.shouldRemainVisible(_:)`（= 自分が消費した
/// F4-1 / F4-3 だけを除いた再判定）を毎回見て、Plus 化・オフライン・ステータス変更が起きたら畳む。
struct PlacementAdSlot: View {
    /// 面ごとの広告フォーマット（`docs/07-monetization.md` §7.2 の配置表）。
    /// 判定・ラッチのロジックは共通なので、描画する `DesignSystem` の枠だけを切り替える。
    enum Format {
        /// インライン・アダプティブバナー（名義一覧 / 名義詳細 / ツアー表）
        case banner
        /// ネイティブ（ホーム最下部 / 申込一覧インライン）
        case native
    }

    @Environment(AdsStore.self) private var adsStore
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.adsBridge) private var adsBridge
    @Environment(\.adRenderer) private var adRenderer

    let placement: AdPlacement
    var format: Format = .banner

    @State private var isVisible = false

    /// 判定のやり直し間隔。起動 30 秒（F4-2）/ ステータス変更 60 秒（F4-5）のクールダウンが
    /// 明けたときに、画面を開き直さなくても枠が出るようにする（AC-AD-38 / AC-AD-39）。
    private static let recheckInterval: Duration = .seconds(5)
    /// 最大観測回数（≒120 秒）。両クールダウンより十分長い時間だけ見張って止める（電力）。
    private static let maxChecks = 24

    var body: some View {
        slot
            .task {
                for _ in 0..<Self.maxChecks {
                    // 機内モード/圏外を測り直して `AdsStore` に反映する（F4-4 / AC-AD-40）
                    await adsBridge.refreshOnline()
                    guard !Task.isCancelled else { return }
                    update()
                    try? await Task.sleep(for: Self.recheckInterval)
                    guard !Task.isCancelled else { return }
                }
            }
    }

    @ViewBuilder
    private var slot: some View {
        let adUnitID = adsBridge.adUnitID(for: placement)
        switch format {
        case .banner:
            AdSlot(isVisible: isVisible, adUnitID: adUnitID)
        case .native:
            NativeAdSlot(isVisible: isVisible, adUnitID: adUnitID)
        }
    }

    @MainActor
    private func update() {
        // Plus（grace 中含む）は広告を一切出さない（F4-6）。`GET /v1/me` の結果は `ProfileStore` が持つので、
        // 判定の直前に `AdsStore` へ写す（App 側に観測配線を増やさず、常に最新の entitlement で判定する）
        if let entitlement = profileStore.entitlement {
            adsStore.applyEntitlement(plan: entitlement.plan, inGracePeriod: entitlement.inGracePeriod)
        }

        // SDK 未注入（プレビュー・UI テスト）やユニット ID 未設定では枠を出さないし、
        // **インプレッションとしても数えない**（セッション 3 枚上限 F4-1 を空振りで消費しない / AC-AD-36）
        guard adRenderer != nil, !adsBridge.adUnitID(for: placement).isEmpty else {
            isVisible = false
            return
        }

        if isVisible {
            // 表示中でも Plus 化（F4-6）・オフライン（F4-4 / AC-AD-40）・ステータス変更（F4-5 / AC-AD-39）
            // は即座に効かせて枠ごと畳む。自分が消費した F4-1 / F4-3 だけを除いた再判定を使う
            if !adsStore.shouldRemainVisible(placement) { isVisible = false }
            return
        }

        guard adsStore.shouldShow(placement) else { return }
        isVisible = true
        adsStore.recordImpression(placement)
    }
}
