import XCTest
@testable import Domain

/// `IdentityStore.deleteIdentity`（Issue #11 dT4 / `docs/plans/delete-ui/plan.md` T4）。
/// `ApplicationStore.deleteApplication` と同じ非楽観パターンを踏襲する。
@MainActor
final class IdentityStoreDeleteTests: XCTestCase {
    private let identityID = UUID(uuidString: "00000000-0000-7000-8000-000000000001")!
    private let otherIdentityID = UUID(uuidString: "00000000-0000-7000-8000-000000000002")!

    // MARK: - 成功 / 失敗（FakeIdentityRepository）

    func testDeleteIdentitySuccessRemovesIdentityAndItsMemberships() async {
        let identity = makeIdentity(id: identityID)
        let other = makeIdentity(id: otherIdentityID)
        let ownMembership = Membership(identityID: identityID, fanClubNameRaw: "FC-A")
        let otherMembership = Membership(identityID: otherIdentityID, fanClubNameRaw: "FC-B")

        let repository = FakeIdentityRepository()
        let store = IdentityStore(repository: repository)
        store.identities = [identity, other]
        store.memberships = [ownMembership, otherMembership]

        let result = await store.deleteIdentity(identityID)

        XCTAssertTrue(result)
        XCTAssertEqual(store.identities.map(\.id), [other.id])
        XCTAssertEqual(store.memberships.map(\.id), [otherMembership.id])
        XCTAssertNil(store.actionError)
        let calls = await repository.deleteCalls
        XCTAssertEqual(calls, [identityID])
    }

    func testDeleteIdentityFailureKeepsStateUnchangedAndSetsActionError() async {
        let identity = makeIdentity(id: identityID)
        let membership = Membership(identityID: identityID, fanClubNameRaw: "FC-A")
        let repository = FakeIdentityRepository()
        await repository.setFailure(.offline)
        let store = IdentityStore(repository: repository)
        store.identities = [identity]
        store.memberships = [membership]

        let result = await store.deleteIdentity(identityID)

        XCTAssertFalse(result)
        XCTAssertEqual(store.identities.map(\.id), [identityID], "失敗時は削除しない（楽観更新しない）")
        XCTAssertEqual(store.memberships.map(\.id), [membership.id])
        XCTAssertEqual(store.actionError, .offline)
    }

    func testDeleteIdentityWithoutRepositoryRemovesLocally() async {
        let identity = makeIdentity(id: identityID)
        let membership = Membership(identityID: identityID, fanClubNameRaw: "FC-A")
        let store = IdentityStore() // repository なし = ローカル経路
        store.identities = [identity]
        store.memberships = [membership]

        let result = await store.deleteIdentity(identityID)

        XCTAssertTrue(result)
        XCTAssertTrue(store.identities.isEmpty)
        XCTAssertTrue(store.memberships.isEmpty)
    }

    func testDeleteIdentityDoesNotReferenceApplicationStore() async {
        // IOS-5 相当の方針確認: IdentityStore は ApplicationRepository / ApplicationStore を
        // 一切知らずに削除できる（コンパイルが通ること自体がこのテストの主張）。
        let identity = makeIdentity(id: identityID)
        let repository = FakeIdentityRepository()
        let store = IdentityStore(repository: repository)
        store.identities = [identity]

        let result = await store.deleteIdentity(identityID)

        XCTAssertTrue(result)
    }

    // MARK: - InMemory フェイクの連鎖セマンティクス

    func testInMemoryIdentityRepositoryDeleteCascadesToMembershipsAndClearsRepMembershipID() async throws {
        let membership = Membership(identityID: identityID, fanClubNameRaw: "FC-A")
        let application = ApplicationEntry(
            id: UUID(),
            tourID: UUID(),
            eventID: UUID(),
            repIdentityID: identityID,
            repMembershipID: membership.id,
            status: .applied
        )
        let membershipRepository = InMemoryMembershipRepository(items: [membership])
        let applicationRepository = InMemoryApplicationRepository(items: [application], tours: [])
        let identityRepository = InMemoryIdentityRepository(
            items: [makeIdentity(id: identityID)],
            membershipRepository: membershipRepository,
            applicationRepository: applicationRepository
        )

        try await identityRepository.delete(id: identityID)

        let remainingIdentities = try await identityRepository.list()
        XCTAssertTrue(remainingIdentities.isEmpty)
        let remainingMemberships = try await membershipRepository.list()
        XCTAssertTrue(remainingMemberships.isEmpty)
        let remainingApplications = try await applicationRepository.listPage(limit: 10, cursor: nil)
        XCTAssertEqual(remainingApplications.items.first?.repMembershipID, nil)
    }

    // MARK: - ヘルパー

    private func makeIdentity(id: UUID) -> Identity {
        Identity(id: id, displayName: "テスト名義", relation: .self, colorHex: "#FF0000")
    }
}

// MARK: - フェイク

actor FakeIdentityRepository: IdentityRepository {
    private(set) var deleteCalls: [UUID] = []
    private var failure: AppError?

    func setFailure(_ error: AppError?) { failure = error }

    func list() async throws -> [Identity] { [] }

    func create(_ identity: Identity) async throws -> Identity { identity }

    func update(id: UUID, _ patch: IdentityPatch) async throws -> Identity {
        throw AppError.notFound
    }

    func delete(id: UUID) async throws {
        deleteCalls.append(id)
        if let failure { throw failure }
    }
}
