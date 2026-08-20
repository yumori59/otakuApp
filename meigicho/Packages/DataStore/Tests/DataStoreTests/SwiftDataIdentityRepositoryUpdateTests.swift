import XCTest
import SwiftData
@testable import DataStore
import Domain

/// `SwiftDataIdentityRepository.update` の回帰テスト（Issue #11 TE-2）。
/// 対象は既存実装（`SwiftDataIdentityRepository.swift:40-50`）。製品コードは変更せず、
/// 「更新で SwiftData 行が変わり outbox に積まれ updatedAt が進む」「削除済みへの更新は notFound」を固定化する。
@MainActor
final class SwiftDataIdentityRepositoryUpdateTests: XCTestCase {
    private func makeIdentity(
        _ container: ModelContainer,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) async throws -> Identity {
        let repository = SwiftDataIdentityRepository(container: container)
        return try await repository.create(
            Identity(
                displayName: "本人",
                relation: .self,
                colorHex: "#0017C1",
                updatedAt: updatedAt
            )
        )
    }

    /// 更新で SwiftData 行が変わり、outbox に `identities` が1件積まれ、`updatedAt` が進む。
    func testUpdateChangesRecordAndEnqueuesOutboxAndAdvancesUpdatedAt() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let repository = SwiftDataIdentityRepository(container: container)

        var patch = IdentityPatch()
        patch.displayName = .set("改名後")
        patch.note = .set("更新メモ")
        let updated = try await repository.update(id: identity.id, patch)
        XCTAssertEqual(updated.displayName, "改名後")
        XCTAssertEqual(updated.note, "更新メモ")

        let context = ModelContext(container)
        let record = try XCTUnwrap(try IdentityRecord.fetchRecord(id: identity.id, in: context))
        XCTAssertEqual(record.displayName, "改名後")
        XCTAssertGreaterThan(record.updatedAt, identity.updatedAt, "更新で updatedAt が進む")

        // create と update が同じ id を対象にするので outbox は重複せず1件のまま。
        let outbox = try context.fetch(FetchDescriptor<OutboxEntry>())
        XCTAssertEqual(outbox.filter { $0.collection == .identities }.count, 1)
    }

    /// 削除済み名義への更新は `.notFound`。
    func testUpdateDeletedIdentityThrowsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await makeIdentity(container)
        let repository = SwiftDataIdentityRepository(container: container)
        try await repository.delete(id: identity.id)

        var patch = IdentityPatch()
        patch.displayName = .set("改名後")
        do {
            _ = try await repository.update(id: identity.id, patch)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }

    /// 存在しない id への更新も `.notFound`。
    func testUpdateUnknownIdentityThrowsNotFound() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let repository = SwiftDataIdentityRepository(container: container)

        var patch = IdentityPatch()
        patch.displayName = .set("改名後")
        do {
            _ = try await repository.update(id: UUID(), patch)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? AppError, .notFound)
        }
    }
}
