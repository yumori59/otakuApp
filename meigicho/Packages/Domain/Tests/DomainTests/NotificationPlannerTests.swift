import XCTest
import Foundation
import Core
@testable import Domain

final class NotificationPlannerTests: XCTestCase {
    private let calendar = Calendar.jst

    func testRenewalNotificationsAt30And14And1Days() throws {
        let renewal = try XCTUnwrap(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 11, day: 3)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 9, day: 1, hour: 12)))

        let membershipID = UUID(uuidString: "00000000-0000-4000-8000-000000000501")!
        let identityID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let specs = NotificationPlanner.plan(
            memberships: [
                MembershipSnapshot(
                    id: membershipID,
                    identityID: identityID,
                    identityName: "佐藤 (自分)",
                    fanClubName: "STELLARIS FC",
                    renewalOn: renewal
                ),
            ],
            applications: [],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(specs.count, 3)
        XCTAssertTrue(specs.allSatisfy { $0.id.hasPrefix("renewal:\(membershipID.uuidString):") })
        XCTAssertEqual(specs.map(\.id), [
            "renewal:\(membershipID.uuidString):30",
            "renewal:\(membershipID.uuidString):14",
            "renewal:\(membershipID.uuidString):1",
        ])
    }

    func testResultNotificationOnlyForAppliedStatus() throws {
        let resultOn = try XCTUnwrap(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 8, day: 20)))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(timeZone: calendar.timeZone, year: 2026, month: 8, day: 1)))

        let appID = UUID(uuidString: "00000000-0000-4000-8000-000000000601")!
        let specs = NotificationPlanner.plan(
            memberships: [],
            applications: [
                ApplicationSnapshot(id: appID, eventName: "大阪公演", repName: "本人", resultOn: resultOn, status: .applied),
                ApplicationSnapshot(id: UUID(), eventName: "名古屋公演", repName: "妹", resultOn: resultOn, status: .won),
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs.first?.id, "result:\(appID.uuidString)")
        XCTAssertEqual(specs.first?.title, "本日、当落発表です")
    }

    func testCapsAt64PendingNotifications() {
        var memberships: [MembershipSnapshot] = []
        for index in 0..<30 {
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index + 1))!
            memberships.append(MembershipSnapshot(
                id: id,
                identityID: id,
                identityName: "名義\(index)",
                fanClubName: "FC\(index)",
                renewalOn: calendar.date(byAdding: .day, value: 60, to: SampleData.referenceDate)
            ))
        }

        let specs = NotificationPlanner.plan(
            memberships: memberships,
            applications: [],
            now: SampleData.referenceDate,
            calendar: calendar
        )

        XCTAssertEqual(specs.count, NotificationPlanner.maxPending)
        XCTAssertTrue(specs.first!.fireDate <= specs.last!.fireDate)
    }
}
