import Foundation

/// 同期 UI 用ステータス（`docs/05` §5）。成功は出さず、失敗・未送信だけ出す前提。
public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case upToDate(at: Date)
    case offline
    case failed(message: String)
}

public enum SyncTrigger: String, Sendable {
    case launch
    case foreground
    case edit
    case manual
}

/// `@MainActor` で UI が購読する同期状態。
@MainActor
@Observable
public final class SyncStatusStore: @unchecked Sendable {
    public private(set) var status: SyncStatus = .idle
    public private(set) var pendingCount: Int = 0

    public init() {}

    public func apply(_ status: SyncStatus) {
        self.status = status
    }

    public func setPendingCount(_ count: Int) {
        pendingCount = count
    }
}
