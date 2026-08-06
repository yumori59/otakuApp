import XCTest
@testable import Domain

final class DuplicateApplicationTests: XCTestCase {
    func testDetectsDuplicateEventFromSampleData() {
        let duplicates = DuplicateApplicationDetection.duplicateEventIDs(in: SampleData.applications)
        XCTAssertTrue(duplicates.contains(SampleData.applications[0].eventID))
        XCTAssertEqual(SampleData.applications[0].eventID, SampleData.applications[1].eventID)
    }

    func testCoApplicationsReturnsAllEntriesForEvent() {
        let eventID = SampleData.applications[0].eventID
        let group = DuplicateApplicationDetection.coApplications(for: eventID, in: SampleData.applications)
        XCTAssertEqual(group.count, 2)
    }

    func testSingleApplicationIsNotDuplicate() {
        let single = [SampleData.applications[2]]
        XCTAssertTrue(DuplicateApplicationDetection.duplicateEventIDs(in: single).isEmpty)
    }
}
