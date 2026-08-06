import Foundation
import UserNotifications
import Domain
import Core

/// `UNUserNotificationCenter` への登録（App 層）。
@MainActor
final class NotificationScheduler {
    private let center = UNUserNotificationCenter.current()

    func reschedule(_ specs: [NotificationRequestSpec]) async {
        center.removeAllPendingNotificationRequests()
        guard !specs.isEmpty else { return }

        for spec in specs {
            let content = UNMutableNotificationContent()
            content.title = spec.title
            content.body = spec.body
            content.sound = .default
            content.userInfo = ["deepLink": spec.deepLink.absoluteString]

            var components = Calendar.jst.dateComponents([.year, .month, .day, .hour, .minute], from: spec.fireDate)
            components.timeZone = TimeZone(identifier: "Asia/Tokyo")
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: spec.id, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                // 個別失敗は他の通知登録を止めない
            }
        }
    }

    func reschedule(
        identityStore: IdentityStore,
        applicationStore: ApplicationStore,
        now: Date = Date()
    ) async {
        let identityNames = Dictionary(uniqueKeysWithValues: identityStore.identities.map { ($0.id, $0.displayName) })

        let membershipSnapshots = identityStore.memberships.map { membership in
            MembershipSnapshot(
                id: membership.id,
                identityID: membership.identityID,
                identityName: identityNames[membership.identityID] ?? "名義",
                fanClubName: membership.fanClubNameRaw,
                renewalOn: membership.renewalOn
            )
        }

        let applicationSnapshots = applicationStore.applications.map { application in
            let display = applicationStore.display(for: application)
            let repName = identityStore.identity(for: application.repIdentityID)?.displayName ?? "代表者"
            return ApplicationSnapshot(
                id: application.id,
                eventName: display.eventName ?? "公演",
                repName: repName,
                resultOn: application.resultOn,
                status: application.status
            )
        }

        let specs = NotificationPlanner.plan(
            memberships: membershipSnapshots,
            applications: applicationSnapshots,
            now: now,
            calendar: .jst
        )
        await reschedule(specs)
    }
}
