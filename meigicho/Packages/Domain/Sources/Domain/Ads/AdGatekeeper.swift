import Foundation

/// 広告の表示可否を判定する純粋型。SDK（GoogleMobileAds）には一切依存しない。
///
/// `docs/plans/admob-integration/requirements.md` F4-1〜F4-6 の 6 条件を集約する
/// （`.claude/rules/01-aidlc.md`「iOS の振る舞いロジックは Domain / Core の純粋関数に寄せる」/
/// `docs/plans/admob-integration/plan.md` §4 D2）。View / SDK 層は判定結果を受け取るだけにする。
public struct AdGatekeeper: Sendable {
    /// 判定に必要な入力値。呼び出し側（`AdsStore`）が現在の状態から都度組み立てる。
    public struct Input: Sendable {
        /// F4-6: Plus（grace 中含む）は広告を一切描画しない。
        public var plan: Plan
        public var inGracePeriod: Bool
        /// F4-4: オフライン時は枠自体を出さない。
        public var isOnline: Bool
        /// F4-2: 起動から 30 秒間はリクエストしない。
        public var appLaunchedAt: Date
        /// F4-5: ステータス変更後 60 秒間は全広告リクエストを止める。未変更なら `nil`。
        public var lastStatusChangeAt: Date?
        /// F4-1: 1 セッション最大 3 インプレッション。
        public var sessionImpressionCount: Int
        /// F4-3: 同一画面で連続 2 枚を出さない（直前に表示した面と同じ面の再要求を弾く）。
        public var lastShownPlacement: AdPlacement?
        public var now: Date

        public init(
            plan: Plan,
            inGracePeriod: Bool,
            isOnline: Bool,
            appLaunchedAt: Date,
            lastStatusChangeAt: Date?,
            sessionImpressionCount: Int,
            lastShownPlacement: AdPlacement?,
            now: Date
        ) {
            self.plan = plan
            self.inGracePeriod = inGracePeriod
            self.isOnline = isOnline
            self.appLaunchedAt = appLaunchedAt
            self.lastStatusChangeAt = lastStatusChangeAt
            self.sessionImpressionCount = sessionImpressionCount
            self.lastShownPlacement = lastShownPlacement
            self.now = now
        }
    }

    /// 起動から広告リクエストを止める最小秒数（F4-2）。
    public static let launchCooldown: TimeInterval = 30
    /// ステータス変更後に全広告リクエストを止める秒数（F4-5）。
    public static let statusChangeCooldown: TimeInterval = 60
    /// 1 セッションあたりの最大インプレッション数（F4-1）。
    public static let maxSessionImpressions = 3

    public init() {}

    /// `placement` を今表示してよいかを判定する。
    public func shouldShow(_ placement: AdPlacement, input: Input) -> Bool {
        // F4-6: Plus（grace 中含む）は常に非表示。
        if input.plan == .plus || input.inGracePeriod { return false }
        // F4-4: オフラインは常に非表示。
        if !input.isOnline { return false }
        // F4-2: 起動 30 秒未満は非表示。
        if input.now.timeIntervalSince(input.appLaunchedAt) < Self.launchCooldown { return false }
        // F4-1: セッション上限到達で非表示。
        if input.sessionImpressionCount >= Self.maxSessionImpressions { return false }
        // F4-5: ステータス変更直後 60 秒は非表示。
        if let lastStatusChangeAt = input.lastStatusChangeAt,
           input.now.timeIntervalSince(lastStatusChangeAt) < Self.statusChangeCooldown {
            return false
        }
        // F4-3: 直前に表示した面と同じ面の連続表示は非表示。
        if input.lastShownPlacement == placement { return false }
        return true
    }

    /// **すでに表示中**の `placement` を出し続けてよいかを判定する。
    ///
    /// `shouldShow` をそのまま再評価すると、自分が記録したインプレッションによって
    /// F4-1（セッション上限）と F4-3（`lastShownPlacement == placement`）が必ず false に反転し、
    /// 表示した瞬間に枠が消えてしまう。そこで**自分が消費した 2 条件だけを除いて**再評価する。
    /// Plus への切り替え（F4-6）・オフライン化（F4-4）・ステータス変更（F4-5）は
    /// 表示中でも即座に効かせる。
    public func shouldRemainVisible(_ placement: AdPlacement, input: Input) -> Bool {
        if input.plan == .plus || input.inGracePeriod { return false }
        if !input.isOnline { return false }
        if input.now.timeIntervalSince(input.appLaunchedAt) < Self.launchCooldown { return false }
        if let lastStatusChangeAt = input.lastStatusChangeAt,
           input.now.timeIntervalSince(lastStatusChangeAt) < Self.statusChangeCooldown {
            return false
        }
        return true
    }
}
