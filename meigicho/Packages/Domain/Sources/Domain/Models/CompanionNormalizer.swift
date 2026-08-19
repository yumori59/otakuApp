import Foundation

/// `Companion` 配列の正規化ロジックの単一の実体。
///
/// `ApplicationStore.normalizedCompanions`（`@MainActor`）と
/// `ApplicationEditPlanner`（View に依存しない純粋関数・非 actor）の両方から使うため、
/// actor 分離のない自由関数として切り出す（重複実装を避けるための最小限の共通化）。
public enum CompanionNormalizer {
    /// `api-contract.md` §7「companions は 0〜3 件」
    public static let maxCompanions = 3

    /// 0〜3 件 / `identity_id` 重複除去 / `position` を 0 起点連番に振り直す。`id` は保持する。
    public static func normalize(_ companions: [Companion]) -> [Companion] {
        var seen = Set<UUID>()
        var result: [Companion] = []
        for companion in companions.sorted(by: { $0.position < $1.position }) {
            if let identityID = companion.identityID {
                guard seen.insert(identityID).inserted else { continue }
            }
            guard result.count < maxCompanions else { break }
            result.append(
                Companion(
                    id: companion.id,
                    identityID: companion.identityID,
                    displayName: companion.displayName,
                    position: result.count
                )
            )
        }
        return result
    }
}
