import XCTest
import SwiftData
@testable import DataStore
import Domain
import Core

@MainActor
final class SyncEngineCollectionsTests: XCTestCase {
    private func makeEngine(
        container: ModelContainer,
        remote: MultiCollectionSyncRepository,
        statusStore: SyncStatusStore
    ) async -> SyncEngine {
        let reachability = Reachability()
        await reachability.set(isOnline: true)
        return SyncEngine(
            container: container,
            remote: remote,
            reachability: reachability,
            statusSink: .binding(statusStore),
            cursorDefaultsKey: "meigicho.sync.test.\(UUID().uuidString)"
        )
    }

    /// AC-SY-03 前半: Outbox の全コレクションを依存順で push する。
    func testPushesAllCollectionsInDependencyOrder() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identities = SwiftDataIdentityRepository(container: container)
        let memberships = SwiftDataMembershipRepository(container: container)
        let applications = SwiftDataApplicationRepository(container: container)

        let identity = try await identities.create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
        _ = try await memberships.create(
            Membership(identityID: identity.id, fanClubNameRaw: "FC A")
        )
        _ = try await applications.create(
            ApplicationDraft(
                tour: TourDraft(name: "TOUR"),
                event: EventDraft(name: "東京公演"),
                repIdentityID: identity.id,
                companions: [Companion(displayName: "同行", position: 0)]
            )
        )

        let remote = MultiCollectionSyncRepository()
        let engine = await makeEngine(container: container, remote: remote, statusStore: SyncStatusStore())
        await engine.runCycleNow(reason: .manual)

        let pushed = await remote.snapshotPushedCollections()
        XCTAssertEqual(
            pushed,
            [.identities, .memberships, .tours, .events, .applications, .applicationCompanions]
        )
        let identityPending = try await identities.pendingCount()
        let membershipPending = try await memberships.pendingCount()
        let applicationPending = try await applications.pendingCount()
        XCTAssertEqual(identityPending, 0)
        XCTAssertEqual(membershipPending, 0)
        XCTAssertEqual(applicationPending, 0)
    }

    /// AC-SY-01: pull の JSON 行が各コレクションのローカル行になる。
    func testPullImportsEveryCollection() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identityID = UUID()
        let membershipID = UUID()
        let tourID = UUID()
        let eventID = UUID()
        let applicationID = UUID()
        let companionID = UUID()
        let updatedAt = "2026-08-01T00:00:00.000Z"

        let remote = MultiCollectionSyncRepository()
        await remote.setPullRows([
            .identities: [[
                "id": .string(identityID.uuidString),
                "display_name": .string("リモート名義"),
                "relation": .string("friend"),
                "color": .string("#FF0000"),
                "history_visible": .bool(false),
                "sort_order": .number(0),
                "updated_at": .string(updatedAt),
                "deleted_at": .null,
            ]],
            .memberships: [[
                "id": .string(membershipID.uuidString),
                "identity_id": .string(identityID.uuidString),
                "fan_club_name_raw": .string("FC B"),
                "member_no_last4": .string("9876"),
                "auto_renew": .bool(true),
                "fee_yen": .number(4400),
                "renewal_on": .string("2026-12-01"),
                "updated_at": .string(updatedAt),
                "deleted_at": .null,
            ]],
            .tours: [[
                "id": .string(tourID.uuidString),
                "name": .string("REMOTE TOUR"),
                "artist_name_raw": .string("ARTIST"),
                "updated_at": .string(updatedAt),
                "deleted_at": .null,
            ]],
            .events: [[
                "id": .string(eventID.uuidString),
                "tour_id": .string(tourID.uuidString),
                "name": .string("大阪公演"),
                "venue_name_raw": .string("京セラドーム"),
                "event_date": .string("2026-09-12"),
                "starts_at": .string("2026-09-12T09:00:00.000Z"),
                "updated_at": .string(updatedAt),
                "deleted_at": .null,
            ]],
            .applications: [[
                "id": .string(applicationID.uuidString),
                "event_id": .string(eventID.uuidString),
                "rep_identity_id": .string(identityID.uuidString),
                "rep_membership_id": .null,
                "status": .string("won"),
                "ticket_count": .number(2),
                "applied_on": .string("2026-07-01"),
                "updated_at": .string(updatedAt),
                "deleted_at": .null,
            ]],
            .applicationCompanions: [[
                "id": .string(companionID.uuidString),
                "application_id": .string(applicationID.uuidString),
                "identity_id": .null,
                "display_name": .string("同行者"),
                "position": .number(0),
                "updated_at": .string(updatedAt),
                "deleted_at": .null,
            ]],
        ])

        let engine = await makeEngine(container: container, remote: remote, statusStore: SyncStatusStore())
        await engine.runCycleNow(reason: .manual)

        let identities = try await SwiftDataIdentityRepository(container: container).list()
        XCTAssertEqual(identities.map(\.id), [identityID])

        let memberships = try await SwiftDataMembershipRepository(container: container).list()
        XCTAssertEqual(memberships.first?.memberNoLast4, "9876")
        XCTAssertEqual(memberships.first?.feeYen, 4400)

        let catalog = SwiftDataCatalogRepository(container: container)
        let tours = try await catalog.listTours()
        XCTAssertEqual(tours.map(\.id), [tourID])
        let event = try await catalog.fetchEvent(id: eventID)
        XCTAssertEqual(event.tourID, tourID)
        XCTAssertEqual(event.venueNameRaw, "京セラドーム")

        let page = try await SwiftDataApplicationRepository(container: container).listPage(limit: 10, cursor: nil)
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items.first?.status, .won)
        XCTAssertEqual(page.items.first?.tourID, tourID)
        XCTAssertEqual(page.items.first?.companions.map(\.displayName), ["同行者"])
    }

    /// AC-SY-03: `SYNC_LWW_REJECT` の行は次の pull でサーバー値に上書きされる。
    func testLWWRejectOverwritesLocalWithServerValue() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let memberships = SwiftDataMembershipRepository(container: container)
        let identity = try await SwiftDataIdentityRepository(container: container).create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
        let local = try await memberships.create(
            Membership(identityID: identity.id, fanClubNameRaw: "ローカル編集", rank: "ローカル")
        )

        let remote = MultiCollectionSyncRepository()
        await remote.setRejectAll(code: "SYNC_LWW_REJECT", message: "server copy is newer")
        // サーバー確定値は **ローカルより古い updated_at**。それでも reject された行は取り込む。
        await remote.setPullRows([
            .memberships: [[
                "id": .string(local.id.uuidString),
                "identity_id": .string(identity.id.uuidString),
                "fan_club_name_raw": .string("サーバー確定"),
                "rank": .string("サーバー"),
                "auto_renew": .bool(false),
                "updated_at": .string("2020-01-01T00:00:00.000Z"),
                "deleted_at": .null,
            ]],
        ])

        let engine = await makeEngine(container: container, remote: remote, statusStore: SyncStatusStore())
        await engine.runCycleNow(reason: .manual)

        let listed = try await memberships.list()
        XCTAssertEqual(listed.first?.fanClubNameRaw, "サーバー確定")
        XCTAssertEqual(listed.first?.rank, "サーバー")
        let pendingAfterMerge = try await memberships.pendingCount()
        XCTAssertEqual(pendingAfterMerge, 0)
    }

    /// AC-SY-04: オフライン中の編集は push されず、行と Outbox が残る。
    func testOfflineEditsSurviveWithoutPush() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let identity = try await SwiftDataIdentityRepository(container: container).create(
            Identity(displayName: "本人", relation: .self, colorHex: "#0017C1")
        )
        let memberships = SwiftDataMembershipRepository(container: container)
        _ = try await memberships.create(Membership(identityID: identity.id, fanClubNameRaw: "オフライン作成"))

        let remote = MultiCollectionSyncRepository()
        let reachability = Reachability()
        await reachability.set(isOnline: false)
        let engine = SyncEngine(
            container: container,
            remote: remote,
            reachability: reachability,
            statusSink: .binding(SyncStatusStore()),
            cursorDefaultsKey: "meigicho.sync.test.\(UUID().uuidString)"
        )
        await engine.runCycleNow(reason: .manual)

        let pushCallCount = await remote.snapshotPushCallCount()
        XCTAssertEqual(pushCallCount, 0)
        let pendingOffline = try await memberships.pendingCount()
        XCTAssertEqual(pendingOffline, 1)

        // 同じストア（= 再起動後）から読み直しても未送信のまま残る
        let reopened = SwiftDataMembershipRepository(container: container)
        let reopenedList = try await reopened.list()
        XCTAssertEqual(reopenedList.first?.fanClubNameRaw, "オフライン作成")
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutboxEntry>()).count, 2)
    }
}

private actor MultiCollectionSyncRepository: SyncRepository {
    private var pullRows: [SyncCollection: [[String: JSONValue]]] = [:]
    private var pushedCollections: [SyncCollection] = []
    private var pushCallCount = 0
    private var rejectCode: String?
    private var rejectMessage = ""

    func setPullRows(_ rows: [SyncCollection: [[String: JSONValue]]]) {
        pullRows = rows
    }

    func setRejectAll(code: String, message: String) {
        rejectCode = code
        rejectMessage = message
    }

    func snapshotPushedCollections() -> [SyncCollection] { pushedCollections }
    func snapshotPushCallCount() -> Int { pushCallCount }

    func pull(_ request: SyncPullRequest) async throws -> SyncPullResult {
        let rows = pullRows
        pullRows = [:]
        return SyncPullResult(
            changes: rows,
            nextCursor: Date(timeIntervalSince1970: 1_800_000_000),
            hasMore: false
        )
    }

    func push(mutations: [SyncMutation]) async throws -> SyncPushResult {
        pushCallCount += 1
        pushedCollections = mutations.map(\.collection)
        if let rejectCode {
            return SyncPushResult(
                accepted: [],
                rejected: mutations.map {
                    SyncPushRejection(id: $0.id, code: rejectCode, message: rejectMessage)
                },
                serverTime: Date()
            )
        }
        return SyncPushResult(accepted: mutations.map(\.id), rejected: [], serverTime: Date())
    }
}
