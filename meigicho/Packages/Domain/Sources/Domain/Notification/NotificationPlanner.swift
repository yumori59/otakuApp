import Foundation
import Core

/// ローカル通知 1 件分（`docs/05-ios-client.md` §6）。副作用なし。
public struct NotificationRequestSpec: Equatable, Sendable {
    public let id: String
    public let fireDate: Date
    public let title: String
    public let body: String
    public let deepLink: URL

    public init(id: String, fireDate: Date, title: String, body: String, deepLink: URL) {
        self.id = id
        self.fireDate = fireDate
        self.title = title
        self.body = body
        self.deepLink = deepLink
    }
}

public struct MembershipSnapshot: Equatable, Sendable {
    public let id: UUID
    public let identityID: UUID
    public let identityName: String
    public let fanClubName: String
    public let renewalOn: Date?

    public init(id: UUID, identityID: UUID, identityName: String, fanClubName: String, renewalOn: Date?) {
        self.id = id
        self.identityID = identityID
        self.identityName = identityName
        self.fanClubName = fanClubName
        self.renewalOn = renewalOn
    }
}

public struct ApplicationSnapshot: Equatable, Sendable {
    public let id: UUID
    public let eventName: String
    public let repName: String
    public let resultOn: Date?
    public let status: ApplicationStatus

    public init(id: UUID, eventName: String, repName: String, resultOn: Date?, status: ApplicationStatus) {
        self.id = id
        self.eventName = eventName
        self.repName = repName
        self.resultOn = resultOn
        self.status = status
    }
}

/// 純関数プランナ。`UNUserNotificationCenter` の 64 件上限をここで守る。
public enum NotificationPlanner {
    public static let maxPending = 64

    public static func plan(
        memberships: [MembershipSnapshot],
        applications: [ApplicationSnapshot],
        now: Date,
        calendar: Calendar = .jst
    ) -> [NotificationRequestSpec] {
        var specs: [NotificationRequestSpec] = []

        for membership in memberships {
            guard let renewal = membership.renewalOn else { continue }
            for daysBefore in [30, 14, 1] {
                guard let day = calendar.date(byAdding: .day, value: -daysBefore, to: renewal),
                      let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                      fire > now
                else { continue }

                let renewalLabel = DateFormatting.formatDate(renewal, withWeekday: false)
                specs.append(NotificationRequestSpec(
                    id: "renewal:\(membership.id.uuidString):\(daysBefore)",
                    fireDate: fire,
                    title: "FC更新期限まであと\(daysBefore)日",
                    body: "\(membership.identityName)／\(membership.fanClubName)（更新日 \(renewalLabel)）",
                    deepLink: URL(string: "meigicho://identity/\(membership.identityID.uuidString)")!
                ))
            }
        }

        for application in applications where application.status == .applied {
            guard let result = application.resultOn,
                  let fire = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: result),
                  fire > now
            else { continue }

            specs.append(NotificationRequestSpec(
                id: "result:\(application.id.uuidString)",
                fireDate: fire,
                title: "本日、当落発表です",
                body: "\(application.eventName)（代表: \(application.repName)）",
                deepLink: URL(string: "meigicho://application/\(application.id.uuidString)")!
            ))
        }

        return Array(specs.sorted { $0.fireDate < $1.fireDate }.prefix(maxPending))
    }
}
