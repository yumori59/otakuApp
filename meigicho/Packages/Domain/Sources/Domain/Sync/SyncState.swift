import Foundation

/// ローカル行の同期状態（`docs/05` §2.2）。SwiftData の `#Predicate` 用に raw Int で永続化する。
public enum SyncState: Int, Codable, Sendable, Equatable {
    case synced = 0
    case pendingCreate = 1
    case pendingUpdate = 2
    case pendingDelete = 3
    case conflicted = 4
}
