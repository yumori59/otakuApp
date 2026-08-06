import SwiftUI

/// App 層の通知処理を Features から呼ぶための橋（Composition Root が実装を注入する）。
public struct NotificationBridge: @unchecked Sendable {
    public var isDenied: @MainActor () -> Bool
    public var refreshPermission: @MainActor () async -> Void
    public var requestAndSchedule: @MainActor () async -> Void
    public var rescheduleIfAuthorized: @MainActor () async -> Void
    public var openSettings: @MainActor () -> Void

    public init(
        isDenied: @escaping @MainActor () -> Bool = { false },
        refreshPermission: @escaping @MainActor () async -> Void = {},
        requestAndSchedule: @escaping @MainActor () async -> Void = {},
        rescheduleIfAuthorized: @escaping @MainActor () async -> Void = {},
        openSettings: @escaping @MainActor () -> Void = {}
    ) {
        self.isDenied = isDenied
        self.refreshPermission = refreshPermission
        self.requestAndSchedule = requestAndSchedule
        self.rescheduleIfAuthorized = rescheduleIfAuthorized
        self.openSettings = openSettings
    }

    public static let noop = NotificationBridge()
}

private struct NotificationBridgeKey: EnvironmentKey {
    static let defaultValue = NotificationBridge.noop
}

extension EnvironmentValues {
    public var notificationBridge: NotificationBridge {
        get { self[NotificationBridgeKey.self] }
        set { self[NotificationBridgeKey.self] = newValue }
    }
}
