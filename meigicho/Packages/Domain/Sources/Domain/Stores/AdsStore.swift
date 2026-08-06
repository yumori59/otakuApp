import Foundation
import Core

/// 広告表示のセッション状態を保持し、`AdGatekeeper` へ渡すオーケストレーション層。
/// SDK（GoogleMobileAds）には依存しない（`docs/plans/admob-integration/plan.md` §4 D2, D4）。
@MainActor
@Observable
public final class AdsStore {
    public private(set) var plan: Plan = .free
    public private(set) var inGracePeriod = false
    public private(set) var isOnline = true
    public let appLaunchedAt: Date
    public private(set) var lastStatusChangeAt: Date?
    public private(set) var sessionImpressionCount = 0
    public private(set) var lastShownPlacement: AdPlacement?

    private let gatekeeper = AdGatekeeper()
    private let now: () -> Date

    public init(appLaunchedAt: Date = Date(), now: @escaping () -> Date = Date.init) {
        self.appLaunchedAt = appLaunchedAt
        self.now = now
    }

    /// `GET /v1/me` の `entitlement` 反映時に呼ぶ（F4-6）。
    public func applyEntitlement(plan: Plan, inGracePeriod: Bool) {
        self.plan = plan
        self.inGracePeriod = inGracePeriod
    }

    /// ネットワーク経路の可否を反映する（F4-4）。
    public func setOnline(_ isOnline: Bool) {
        self.isOnline = isOnline
    }

    /// 当落ステータスが切り替わった瞬間に呼ぶ（F4-5）。
    public func recordStatusChange(at date: Date? = nil) {
        lastStatusChangeAt = date ?? now()
    }

    /// 広告が実際に表示された（インプレッションが発生した）ときに呼ぶ（F4-1, F4-3）。
    public func recordImpression(_ placement: AdPlacement) {
        sessionImpressionCount += 1
        lastShownPlacement = placement
    }

    /// バックグラウンドから復帰したときに呼ぶ。`backgroundDuration` が 30 秒以上ならセッションをリセットする
    /// （Q10 のセッション定義 / AC-AD-28）。30 秒未満はセッションを継続する。
    public func handleForegroundReturn(backgroundDuration: TimeInterval) {
        guard backgroundDuration >= AdGatekeeper.launchCooldown else { return }
        resetSession()
    }

    /// セッションのインプレッション状態を初期化する。
    public func resetSession() {
        sessionImpressionCount = 0
        lastShownPlacement = nil
    }

    /// `placement` を今表示してよいかを判定する。
    public func shouldShow(_ placement: AdPlacement) -> Bool {
        let input = AdGatekeeper.Input(
            plan: plan,
            inGracePeriod: inGracePeriod,
            isOnline: isOnline,
            appLaunchedAt: appLaunchedAt,
            lastStatusChangeAt: lastStatusChangeAt,
            sessionImpressionCount: sessionImpressionCount,
            lastShownPlacement: lastShownPlacement,
            now: now()
        )
        return gatekeeper.shouldShow(placement, input: input)
    }
}
