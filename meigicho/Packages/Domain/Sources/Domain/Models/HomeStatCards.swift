import Foundation

/// ホーム画面の3指標カード（管理中の名義 / 30日以内更新期限 / 当落発表待ち）の表示値。
///
/// `HomeSummary`（`GET /v1/home/summary` のスナップショット）は `HomeStore.load()` を
/// 呼び直すまで更新されない。一方 `pendingResults` は申込のステータス変更（`ApplicationStore`）で
/// ローカル SwiftData へ即時反映される SSoT があるため、**表示直前に常にローカル値で上書きする**
/// （バグ修正: ステータスを「申込中」に変更しても当落発表待ちカードが増えなかった）。
///
/// `identityCount` / `renewalsWithin30Days` は同種のローカル即時反映口が無いため、
/// summary 取得済みならサーバー集計を優先し、未取得時のみローカル集計へフォールバックする
/// （`HomeView.statCards` の従来挙動を維持）。
public struct HomeStatCards: Equatable, Sendable {
    public let identityCount: Int
    public let renewalsWithin30Days: Int
    public let pendingResults: Int

    public init(identityCount: Int, renewalsWithin30Days: Int, pendingResults: Int) {
        self.identityCount = identityCount
        self.renewalsWithin30Days = renewalsWithin30Days
        self.pendingResults = pendingResults
    }

    public static func make(
        summary: HomeSummary?,
        localIdentityCount: Int,
        localExpiringMembershipCount: Int,
        localPendingResults: Int
    ) -> HomeStatCards {
        if let summary {
            return HomeStatCards(
                identityCount: summary.identityCount,
                renewalsWithin30Days: summary.renewalsWithin30Days,
                pendingResults: localPendingResults
            )
        }
        return HomeStatCards(
            identityCount: localIdentityCount,
            renewalsWithin30Days: localExpiringMembershipCount,
            pendingResults: localPendingResults
        )
    }
}
