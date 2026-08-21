import XCTest
@testable import Domain

/// `IdentityStore.updateIdentity` / `.updateMembership` / `.deleteMembership`
/// （Issue #11 TE-3 / `docs/plans/identity-edit-and-delete/plan.md`）。
/// D-4（無変更ならリポジトリを呼ばない）と D-5（非楽観）を検証する。
@MainActor
final class IdentityStoreEditTests: XCTestCase {
    private let identityID = UUID(uuidString: "00000000-0000-7000-8000-000000000001")!
    private let membershipID = UUID(uuidString: "00000000-0000-7000-8000-000000000002")!

    // MARK: - updateIdentity

    func testUpdateIdentityNoChangeDoesNotCallRepository() async {
        let identity = makeIdentity()
        let repository = FakeEditIdentityRepository()
        let store = IdentityStore(repository: repository)
        store.identities = [identity]

        let input = IdentityEditFormInput(
            displayName: identity.displayName,
            relation: identity.relation,
            joinedOn: identity.joinedOn,
            colorHex: identity.colorHex,
            note: identity.note
        )
        let result = await store.updateIdentity(id: identityID, input: input)

        XCTAssertEqual(result, identity)
        let calls = await repository.updateCalls
        XCTAssertTrue(calls.isEmpty, "無変更なら Repository を呼ばない（D-4）")
        XCTAssertNil(store.actionError)
    }

    func testUpdateIdentitySuccessReplacesLocalIdentity() async {
        let identity = makeIdentity()
        let repository = FakeEditIdentityRepository()
        var updated = identity
        updated.displayName = "新しい表示名"
        await repository.setUpdateResult(.success(updated))
        let store = IdentityStore(repository: repository)
        store.identities = [identity]

        let input = IdentityEditFormInput(
            displayName: "新しい表示名",
            relation: identity.relation,
            joinedOn: identity.joinedOn,
            colorHex: identity.colorHex,
            note: identity.note
        )
        let result = await store.updateIdentity(id: identityID, input: input)

        XCTAssertEqual(result?.displayName, "新しい表示名")
        XCTAssertEqual(store.identities.first?.displayName, "新しい表示名")
        XCTAssertNil(store.actionError)
        let calls = await repository.updateCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, identityID)
    }

    func testUpdateIdentityFailureKeepsStateUnchangedAndSetsActionError() async {
        let identity = makeIdentity()
        let repository = FakeEditIdentityRepository()
        await repository.setUpdateResult(.failure(.offline))
        let store = IdentityStore(repository: repository)
        store.identities = [identity]

        let input = IdentityEditFormInput(
            displayName: "変更後の名前",
            relation: identity.relation,
            joinedOn: identity.joinedOn,
            colorHex: identity.colorHex,
            note: identity.note
        )
        let result = await store.updateIdentity(id: identityID, input: input)

        XCTAssertNil(result)
        XCTAssertEqual(store.identities.first?.displayName, identity.displayName, "失敗時は書き換えない（楽観更新しない）")
        XCTAssertEqual(store.actionError, .offline)
    }

    func testUpdateIdentityUnknownIDSetsNotFound() async {
        let repository = FakeEditIdentityRepository()
        let store = IdentityStore(repository: repository)
        store.identities = []

        let input = IdentityEditFormInput(displayName: "x", relation: .self, colorHex: "#FF0000")
        let result = await store.updateIdentity(id: identityID, input: input)

        XCTAssertNil(result)
        XCTAssertEqual(store.actionError, .notFound)
    }

    // MARK: - updateMembership

    func testUpdateMembershipNoChangeDoesNotCallRepository() async {
        let membership = makeMembership()
        let repository = FakeEditMembershipRepository()
        let store = IdentityStore(membershipRepository: repository)
        store.memberships = [membership]

        let input = MembershipEditFormInput(
            fanClubNameRaw: membership.fanClubNameRaw,
            memberNoRaw: membership.memberNo ?? "",
            renewalOn: membership.renewalOn,
            feeYen: membership.feeYen
        )
        let result = await store.updateMembership(id: membershipID, input: input)

        XCTAssertEqual(result, membership)
        let calls = await repository.updateCalls
        XCTAssertTrue(calls.isEmpty, "無変更なら Repository を呼ばない（D-4）")
        XCTAssertNil(store.actionError)
    }

    func testUpdateMembershipSuccessReplacesLocalMembership() async {
        let membership = makeMembership()
        let repository = FakeEditMembershipRepository()
        var updated = membership
        updated.fanClubNameRaw = "新FC"
        await repository.setUpdateResult(.success(updated))
        let store = IdentityStore(membershipRepository: repository)
        store.memberships = [membership]

        let input = MembershipEditFormInput(
            fanClubNameRaw: "新FC",
            memberNoRaw: membership.memberNo ?? "",
            renewalOn: membership.renewalOn,
            feeYen: membership.feeYen
        )
        let result = await store.updateMembership(id: membershipID, input: input)

        XCTAssertEqual(result?.fanClubNameRaw, "新FC")
        XCTAssertEqual(store.memberships.first?.fanClubNameRaw, "新FC")
        XCTAssertNil(store.actionError)
    }

    func testUpdateMembershipFailureKeepsStateUnchangedAndSetsActionError() async {
        let membership = makeMembership()
        let repository = FakeEditMembershipRepository()
        await repository.setUpdateResult(.failure(.offline))
        let store = IdentityStore(membershipRepository: repository)
        store.memberships = [membership]

        let input = MembershipEditFormInput(
            fanClubNameRaw: "新FC",
            memberNoRaw: membership.memberNo ?? "",
            renewalOn: membership.renewalOn,
            feeYen: membership.feeYen
        )
        let result = await store.updateMembership(id: membershipID, input: input)

        XCTAssertNil(result)
        XCTAssertEqual(store.memberships.first?.fanClubNameRaw, membership.fanClubNameRaw)
        XCTAssertEqual(store.actionError, .offline)
    }

    // MARK: - deleteMembership

    func testDeleteMembershipSuccessRemovesFromLocalArray() async {
        let membership = makeMembership()
        let repository = FakeEditMembershipRepository()
        let store = IdentityStore(membershipRepository: repository)
        store.memberships = [membership]

        let result = await store.deleteMembership(membershipID)

        XCTAssertTrue(result)
        XCTAssertTrue(store.memberships.isEmpty)
        XCTAssertNil(store.actionError)
        let calls = await repository.deleteCalls
        XCTAssertEqual(calls, [membershipID])
    }

    func testDeleteMembershipFailureKeepsStateUnchangedAndSetsActionError() async {
        let membership = makeMembership()
        let repository = FakeEditMembershipRepository()
        await repository.setDeleteFailure(.offline)
        let store = IdentityStore(membershipRepository: repository)
        store.memberships = [membership]

        let result = await store.deleteMembership(membershipID)

        XCTAssertFalse(result)
        XCTAssertEqual(store.memberships.map(\.id), [membershipID], "失敗時は削除しない")
        XCTAssertEqual(store.actionError, .offline)
    }

    // MARK: - ヘルパー

    private func makeIdentity() -> Identity {
        Identity(id: identityID, displayName: "テスト名義", relation: .self, colorHex: "#FF0000", joinedOn: nil, note: "")
    }

    private func makeMembership() -> Membership {
        Membership(id: membershipID, identityID: identityID, fanClubNameRaw: "FC-A", memberNo: "1234", renewalOn: nil, feeYen: nil)
    }
}

// MARK: - フェイク

private actor FakeEditIdentityRepository: IdentityRepository {
    private(set) var updateCalls: [(UUID, IdentityPatch)] = []
    private var updateResult: Result<Identity, AppError>?

    func setUpdateResult(_ result: Result<Identity, AppError>) {
        updateResult = result
    }

    func list() async throws -> [Identity] { [] }

    func create(_ identity: Identity) async throws -> Identity { identity }

    func update(id: UUID, _ patch: IdentityPatch) async throws -> Identity {
        updateCalls.append((id, patch))
        switch updateResult {
        case .success(let identity):
            return identity
        case .failure(let error):
            throw error
        case nil:
            throw AppError.notFound
        }
    }

    func delete(id: UUID) async throws {}
}

private actor FakeEditMembershipRepository: MembershipRepository {
    private(set) var updateCalls: [(UUID, MembershipPatch)] = []
    private(set) var deleteCalls: [UUID] = []
    private var updateResult: Result<Membership, AppError>?
    private var deleteFailure: AppError?

    func setUpdateResult(_ result: Result<Membership, AppError>) {
        updateResult = result
    }

    func setDeleteFailure(_ error: AppError?) {
        deleteFailure = error
    }

    func list() async throws -> [Membership] { [] }

    func create(_ membership: Membership) async throws -> Membership { membership }

    func update(id: UUID, _ patch: MembershipPatch) async throws -> Membership {
        updateCalls.append((id, patch))
        switch updateResult {
        case .success(let membership):
            return membership
        case .failure(let error):
            throw error
        case nil:
            throw AppError.notFound
        }
    }

    func delete(id: UUID) async throws {
        deleteCalls.append(id)
        if let deleteFailure { throw deleteFailure }
    }
}
