import XCTest
@testable import Domain

/// バグ修正: ホームの3指標カードのうち「当落発表待ち」は `HomeSummary`（サーバー集計の
/// スナップショット）ではなく、常にローカル SSoT（`ApplicationStore.pendingResultCount()`）
/// の値を使う。`HomeStore.load()` を呼び直すまでサーバー集計は古いままなので、申込の
/// ステータス変更をカードへ即時反映するにはローカル値で上書きする必要がある。
/// 他の2枚（`identityCount` / `renewalsWithin30Days`）は summary 取得済みならサーバー集計を使う。
final class HomeStatCardsTests: XCTestCase {
    func testUsesLocalPendingResultsEvenWhenSummaryIsStale() {
        let staleSummary = HomeSummary(identityCount: 3, renewalsWithin30Days: 1, pendingResults: 5)

        let cards = HomeStatCards.make(
            summary: staleSummary,
            localIdentityCount: 999,
            localExpiringMembershipCount: 999,
            localPendingResults: 2
        )

        // summary が古いままの `pendingResults: 5` ではなく、ローカルの最新値 `2` を使う
        XCTAssertEqual(cards.pendingResults, 2)
        // 他の2枚は summary 取得済みならサーバー集計を優先する（ローカル値の 999 では上書きしない）
        XCTAssertEqual(cards.identityCount, 3)
        XCTAssertEqual(cards.renewalsWithin30Days, 1)
    }

    func testFallsBackToLocalValuesWhenSummaryIsNotLoadedYet() {
        let cards = HomeStatCards.make(
            summary: nil,
            localIdentityCount: 4,
            localExpiringMembershipCount: 2,
            localPendingResults: 1
        )

        XCTAssertEqual(cards.identityCount, 4)
        XCTAssertEqual(cards.renewalsWithin30Days, 2)
        XCTAssertEqual(cards.pendingResults, 1)
    }
}
