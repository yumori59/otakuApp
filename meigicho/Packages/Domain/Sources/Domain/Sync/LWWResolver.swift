import Foundation

/// LWW 競合解決（`docs/05` §5）。純関数 — SyncEngine から直接叩く。
public enum LWWResolver {
    public enum Decision: Equatable, Sendable {
        case takeRemote
        case keepLocal
        case deleteLocal
    }

    /// 削除も「1つの更新」として `updated_at` で比較する。
    public static func resolve(
        localUpdatedAt: Date,
        remoteUpdatedAt: Date,
        remoteDeletedAt: Date?
    ) -> Decision {
        if remoteUpdatedAt > localUpdatedAt {
            return remoteDeletedAt != nil ? .deleteLocal : .takeRemote
        }
        return .keepLocal
    }
}
