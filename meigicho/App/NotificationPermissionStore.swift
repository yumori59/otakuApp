import Foundation
import UserNotifications
import UIKit

/// 通知許可状態（App 層。Features は `NotificationBridge` 経由で参照する）。
@Observable
@MainActor
final class NotificationPermissionStore {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    var isDenied: Bool { authorizationStatus == .denied }
    var isAuthorized: Bool { authorizationStatus == .authorized || authorizationStatus == .provisional }

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refresh()
            return granted
        } catch {
            await refresh()
            return false
        }
    }

    var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }
}
