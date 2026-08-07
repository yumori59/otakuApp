import Foundation

/// 広告を表示してよい 5 面のみを列挙する型。
///
/// `docs/07:407`「フラグで消せる設計にすると、将来の収益改善圧で必ず戻される」という設計意図を
/// **型で担保する**ため、禁止面（申込詳細 / 共有プレビュー / 共有ボード / 入力フォーム全画面 /
/// ステータス変更の瞬間 等 `docs/plans/admob-integration/requirements.md` F3）は
/// **case として存在させない**。禁止画面のソースでは `AdSlot(placement:)` を構築する引数自体が作れない。
/// `docs/05:864-872` にある「禁止面も case に持ち `allowsAds: Bool` で false を返す」方式は、
/// フラグを 1 行書き換えるだけで広告を復活させられてしまうため採用しない
/// （`docs/plans/admob-integration/plan.md` §4 D3）。
public enum AdPlacement: String, CaseIterable, Sendable {
    /// ホーム — 「当落発表待ちの申込」リストの後、画面最下部（ネイティブ小）
    case homeBottom
    /// 名義一覧 — card-list の後、画面最下部（インラインバナー）
    case identitiesBottom
    /// 申込一覧（リスト） — 5件目の後、以降10件ごと（ネイティブ、ticket-row と同じカード形状）
    case applicationsInline
    /// 申込一覧（ツアー表） — tour-group と tour-group の間（インラインバナー。表の内側には入れない）
    case tourTableBetween
    /// 名義詳細 — 「申込履歴」リストの後、画面最下部（インラインバナー）
    case identityDetailBottom
}
