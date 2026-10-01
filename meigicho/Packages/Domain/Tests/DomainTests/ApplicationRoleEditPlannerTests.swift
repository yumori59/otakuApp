import XCTest
@testable import Domain

/// #22: 編集フォームの立場（identity_role / representative_name）差分。
final class ApplicationRoleEditPlannerTests: XCTestCase {
    private let repID = UUID()
    private let tourID = UUID()
    private let eventID = UUID()

    private func makeCurrent(role: ApplicationRole = .representative, name: String? = nil) -> ApplicationEntry {
        ApplicationEntry(
            tourID: tourID, eventID: eventID, repIdentityID: repID,
            identityRole: role, representativeName: name,
            status: .applied
        )
    }

    private let tour = Tour(name: "T", artistNameRaw: "")
    private func event(_ tourID: UUID, _ id: UUID) -> EventEntity { EventEntity(id: id, tourID: tourID, name: "E") }

    private func plan(
        current: ApplicationEntry,
        role: ApplicationRole,
        name: String
    ) -> ApplicationEditPlan {
        let t = Tour(id: tourID, name: "T", artistNameRaw: "")
        let e = event(tourID, eventID)
        let input = ApplicationEditFormInput(
            eventName: "E", tourName: "T", repIdentityID: repID,
            identityRole: role, representativeName: name,
            status: .applied
        )
        return ApplicationEditPlanner.makePlan(current: current, currentTour: t, currentEvent: e, input: input)
    }

    func testNoRoleChangeProducesUnchangedPatch() {
        let p = plan(current: makeCurrent(), role: .representative, name: "").applicationPatch
        XCTAssertEqual(p.identityRole, .unchanged)
        XCTAssertEqual(p.representativeName, .unchanged)
    }

    func testSwitchToCompanionWithNameSendsBoth() {
        let p = plan(current: makeCurrent(), role: .companion, name: " 友人 ").applicationPatch
        XCTAssertEqual(p.identityRole, .set(.companion))
        XCTAssertEqual(p.representativeName, .set("友人"))
    }

    func testSwitchToCompanionWithoutNameSendsRoleOnly() {
        let p = plan(current: makeCurrent(), role: .companion, name: "").applicationPatch
        XCTAssertEqual(p.identityRole, .set(.companion))
        XCTAssertEqual(p.representativeName, .unchanged)
    }

    func testSwitchBackToRepresentativeClearsName() {
        let p = plan(current: makeCurrent(role: .companion, name: "友人"), role: .representative, name: "友人").applicationPatch
        XCTAssertEqual(p.identityRole, .set(.representative))
        XCTAssertEqual(p.representativeName, .set(nil))
    }

    func testCompanionNameEditedAndCleared() {
        let current = makeCurrent(role: .companion, name: "友人")
        XCTAssertEqual(plan(current: current, role: .companion, name: "知人").applicationPatch.representativeName, .set("知人"))
        XCTAssertEqual(plan(current: current, role: .companion, name: "  ").applicationPatch.representativeName, .set(nil))
        XCTAssertEqual(plan(current: current, role: .companion, name: "友人").applicationPatch.representativeName, .unchanged)
    }
}
