import XCTest
import SwiftData
@testable import DataStore
import Domain

final class SwiftDataIdentityRepositoryTests: XCTestCase {
    func testCreateListUpdateAndSoftDelete() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataIdentityRepository(container: container)

        let identity = Identity(
            displayName: "自分",
            relation: .self,
            colorHex: "#0017C1"
        )
        let created = try await repository.create(identity)
        XCTAssertEqual(created.displayName, "自分")

        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 1)

        var patch = IdentityPatch()
        patch.displayName = .set("改名")
        let updated = try await repository.update(id: identity.id, patch)
        XCTAssertEqual(updated.displayName, "改名")

        try await repository.delete(id: identity.id)
        let afterDelete = try await repository.list()
        XCTAssertTrue(afterDelete.isEmpty)

        // soft delete なので pendingDelete として残る
        let pending = try await repository.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    func testDuplicateCreateConflicts() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataIdentityRepository(container: container)
        let identity = Identity(displayName: "A", relation: .other, colorHex: "#000000")
        _ = try await repository.create(identity)
        do {
            _ = try await repository.create(identity)
            XCTFail("expected conflict")
        } catch let error as AppError {
            XCTAssertEqual(error, .conflict)
        }
    }

    func testRoundTripMapping() {
        let identity = Identity(
            displayName: "妹",
            relation: .family,
            colorHex: "#FF00AA",
            historyVisible: true,
            note: "note",
            sortOrder: 2
        )
        let record = IdentityRecord.make(from: identity, syncState: .synced)
        XCTAssertEqual(record.toDomain(), identity)
        XCTAssertEqual(record.syncState, .synced)
    }
}
