import Foundation
import UserNotifications

/// 通知タップ → ディープリンク URL を MainActor で処理する。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let handleURL: @Sendable (URL) async -> Void

    init(handleURL: @escaping @Sendable (URL) async -> Void) {
        self.handleURL = handleURL
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let link = response.notification.request.content.userInfo["deepLink"] as? String,
              let url = URL(string: link)
        else { return }
        await handleURL(url)
    }
}
