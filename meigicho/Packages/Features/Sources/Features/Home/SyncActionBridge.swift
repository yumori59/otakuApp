import SwiftUI

/// App 層（`SyncEngine`）の手動同期呼び出しを Features から使うための橋（ios-sync-engine T4）。
///
/// `Features` は `DataStore` を import しない（AC-SY-05）。同期状態そのものは `Domain.SyncStatusStore`
/// を `@Environment` で直接読めるが、**アクション（手動再試行）だけ**は Composition Root が実体を注入する。
public struct SyncActionBridge: @unchecked Sendable {
    public var retry: @MainActor () async -> Void

    public init(retry: @escaping @MainActor () async -> Void = {}) {
        self.retry = retry
    }

    public static let noop = SyncActionBridge()
}

private struct SyncActionBridgeKey: EnvironmentKey {
    static let defaultValue = SyncActionBridge.noop
}

extension EnvironmentValues {
    public var syncActionBridge: SyncActionBridge {
        get { self[SyncActionBridgeKey.self] }
        set { self[SyncActionBridgeKey.self] = newValue }
    }
}
