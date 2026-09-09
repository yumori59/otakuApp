import Foundation

/// 申込フォームの入力サジェスト（ツアー名 / アーティスト名 / 会場名 / FC名）の候補計算。
///
/// **純粋関数のみ**。候補ソース（`ApplicationStore` / `IdentityStore`）と規則を分離し、
/// 3〜4 フィールドで同じ規則を通す（`docs/plans/input-history-suggestions/plan.md` D-1）。
public enum InputSuggestion {
    /// 候補の表示上限（FR-7）。
    public static let maxSuggestions = 5

    /// 生の値の配列から候補一覧を作る: trim → 空除去 → 重複除去 → 昇順（FR-3）。
    public static func candidates(from values: [String]) -> [String] {
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nonEmpty = trimmed.filter { !$0.isEmpty }
        return Array(Set(nonEmpty)).sorted()
    }

    /// 呼び出し側が決めた並び順を保持したまま候補一覧を作る:
    /// trim → 空除去 → 重複除去（先勝ち）→ 入力順を保持
    /// （`docs/plans/event-name-suggestion/plan.md` D-2。公演名サジェストのように
    /// 昇順以外の並びが必要な候補ソース向け。`candidates(from:)` とは並びの決め方だけが異なる）。
    public static func candidates(fromOrdered values: [String]) -> [String] {
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var seen = Set<String>()
        var result: [String] = []
        for value in trimmed where !value.isEmpty {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }

    /// クエリにマッチする候補を返す: 部分一致・大小無視・完全一致（大小無視）は除外（FR-5）。
    /// クエリが空 / 空白のみなら空配列（FR-5）。上限 `limit` 件まで（FR-7）。
    public static func match(_ candidates: [String], query: String, limit: Int = maxSuggestions) -> [String] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        let matched = candidates.filter {
            $0.localizedCaseInsensitiveContains(trimmedQuery) && $0.caseInsensitiveCompare(trimmedQuery) != .orderedSame
        }
        return Array(matched.prefix(limit))
    }
}
