import Foundation
import Core

// ネットワークを使わない Repository 実装。
// T0 の時点ではアプリ本体もこれを注入する（振る舞い不変の確認のため）。
// T1 以降、`Network` の `Remote*Repository` に差し替わり、これは Preview / テスト専用になる。

public actor InMemoryIdentityRepository: IdentityRepository {
    private var items: [Identity]
    /// 名義削除時の連鎖（`SwiftDataIdentityRepository.delete` と同じセマンティクス）をフェイクでも
    /// 再現するための任意の参照。未指定なら identity 自体の削除のみ（従来の振る舞い）。
    private let membershipRepository: InMemoryMembershipRepository?
    private let applicationRepository: InMemoryApplicationRepository?

    public init(
        items: [Identity] = SampleData.identities,
        membershipRepository: InMemoryMembershipRepository? = nil,
        applicationRepository: InMemoryApplicationRepository? = nil
    ) {
        self.items = items
        self.membershipRepository = membershipRepository
        self.applicationRepository = applicationRepository
    }

    public func list() async throws -> [Identity] { items }

    public func create(_ identity: Identity) async throws -> Identity {
        items.append(identity)
        return identity
    }

    public func update(id: UUID, _ patch: IdentityPatch) async throws -> Identity {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw AppError.notFound }
        var item = items[index]
        item.displayName = patch.displayName.applied(to: item.displayName) ?? item.displayName
        item.relation = patch.relation.applied(to: item.relation) ?? item.relation
        item.colorHex = patch.colorHex.applied(to: item.colorHex) ?? item.colorHex
        item.joinedOn = patch.joinedOn.applied(to: item.joinedOn)
        item.note = patch.note.applied(to: item.note) ?? ""
        item.historyVisible = patch.historyVisible.applied(to: item.historyVisible) ?? item.historyVisible
        item.sortOrder = patch.sortOrder.applied(to: item.sortOrder) ?? item.sortOrder
        items[index] = item
        return item
    }

    /// identity + 配下 membership + それらを参照する application の `repMembershipID` クリアまで
    /// 連鎖する（`membershipRepository` / `applicationRepository` が注入されている場合のみ）。
    public func delete(id: UUID) async throws {
        items.removeAll { $0.id == id }
        guard let membershipRepository else { return }
        let clearedMembershipIDs = await membershipRepository.deleteAll(forIdentityID: id)
        guard let applicationRepository, !clearedMembershipIDs.isEmpty else { return }
        await applicationRepository.clearRepMembershipID(in: Set(clearedMembershipIDs))
    }
}

public actor InMemoryMembershipRepository: MembershipRepository {
    private var items: [Membership]

    public init(items: [Membership] = SampleData.memberships) {
        self.items = items
    }

    public func list() async throws -> [Membership] { items }

    public func create(_ membership: Membership) async throws -> Membership {
        items.append(membership)
        return membership
    }

    public func update(id: UUID, _ patch: MembershipPatch) async throws -> Membership {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw AppError.notFound }
        var item = items[index]
        item.identityID = patch.identityID.applied(to: item.identityID) ?? item.identityID
        item.fanClubNameRaw = patch.fanClubNameRaw.applied(to: item.fanClubNameRaw) ?? item.fanClubNameRaw
        item.memberNo = patch.memberNo.applied(to: item.memberNo)
        item.rank = patch.rank.applied(to: item.rank)
        item.renewalOn = patch.renewalOn.applied(to: item.renewalOn)
        item.feeYen = patch.feeYen.applied(to: item.feeYen)
        item.autoRenew = patch.autoRenew.applied(to: item.autoRenew) ?? item.autoRenew
        item.note = patch.note.applied(to: item.note) ?? ""
        items[index] = item
        return item
    }

    public func delete(id: UUID) async throws {
        items.removeAll { $0.id == id }
    }

    /// 名義削除の連鎖用（`InMemoryIdentityRepository.delete` から呼ばれる）。
    /// 対象 identityID に属する membership を全て削除し、削除した id 一覧を返す。
    func deleteAll(forIdentityID identityID: UUID) -> [UUID] {
        let targetIDs = items.filter { $0.identityID == identityID }.map(\.id)
        items.removeAll { $0.identityID == identityID }
        return targetIDs
    }
}

public actor InMemoryCatalogRepository: CatalogRepository {
    private var tours: [Tour]
    private var events: [EventEntity]

    public init(tours: [Tour] = SampleData.tours, events: [EventEntity] = SampleData.events) {
        self.tours = tours
        self.events = events
    }

    public func listTours() async throws -> [Tour] { tours }

    public func listEvents() async throws -> [EventEntity] { events }

    public func fetchEvent(id: UUID) async throws -> EventEntity {
        guard let event = events.first(where: { $0.id == id }) else { throw AppError.notFound }
        return event
    }

    public func updateTour(id: UUID, _ patch: TourPatch) async throws -> Tour {
        guard let index = tours.firstIndex(where: { $0.id == id }) else { throw AppError.notFound }
        var item = tours[index]
        item.name = patch.name.applied(to: item.name) ?? item.name
        item.artistNameRaw = patch.artistNameRaw.applied(to: item.artistNameRaw) ?? item.artistNameRaw
        tours[index] = item
        return item
    }

    public func updateEvent(id: UUID, _ patch: EventPatch) async throws -> EventEntity {
        guard let index = events.firstIndex(where: { $0.id == id }) else { throw AppError.notFound }
        var item = events[index]
        item.name = patch.name.applied(to: item.name) ?? item.name
        item.venueNameRaw = patch.venueNameRaw.applied(to: item.venueNameRaw) ?? item.venueNameRaw
        item.eventDate = patch.eventDate.applied(to: item.eventDate)
        item.startsAt = patch.startsAt.applied(to: item.startsAt)
        events[index] = item
        return item
    }
}

public actor InMemoryApplicationRepository: ApplicationRepository {
    private var items: [ApplicationEntry]
    /// find-or-create の照合用ツアー名スナップショット。
    /// このフェイクは application の FK（`tourID` / `eventID`）しか持たず、`InMemoryCatalogRepository` の
    /// ツアー本体とは独立したインスタンスなので、常に完全な同期は取れない（両者を既定値
    /// [`SampleData.tours`] のまま使う分には名前が一致する）。`updateScoped` でのツアー名重複を防ぐ
    /// 最小限の目的でのみ使う。
    private var tourNameToID: [String: UUID]

    public init(items: [ApplicationEntry] = SampleData.applications, tours: [Tour] = SampleData.tours) {
        self.items = items
        self.tourNameToID = Dictionary(tours.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
    }

    public func listPage(limit: Int, cursor: String?) async throws -> ApplicationPage {
        ApplicationPage(items: items, nextCursor: nil, hasMore: false)
    }

    public func create(_ draft: ApplicationDraft) async throws -> ApplicationEntry {
        let entry = ApplicationEntry(
            id: draft.id,
            tourID: draft.tour.id,
            eventID: draft.event.id,
            repIdentityID: draft.repIdentityID,
            repMembershipID: draft.repMembershipID,
            roundName: draft.roundName,
            appliedOn: draft.appliedOn,
            resultOn: draft.resultOn,
            status: draft.status,
            seatRaw: draft.seatRaw,
            ticketCount: draft.ticketCount,
            priceYen: draft.priceYen,
            companions: draft.companions,
            note: draft.note
        )
        items.append(entry)
        return entry
    }

    public func update(id: UUID, _ patch: ApplicationPatch) async throws -> ApplicationEntry {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw AppError.notFound }
        var item = items[index]
        item.repIdentityID = patch.repIdentityID.applied(to: item.repIdentityID) ?? item.repIdentityID
        item.repMembershipID = patch.repMembershipID.applied(to: item.repMembershipID)
        item.roundName = patch.roundName.applied(to: item.roundName)
        item.appliedOn = patch.appliedOn.applied(to: item.appliedOn)
        item.resultOn = patch.resultOn.applied(to: item.resultOn)
        item.status = patch.status.applied(to: item.status) ?? item.status
        item.seatRaw = patch.seatRaw.applied(to: item.seatRaw) ?? item.seatRaw
        item.ticketCount = patch.ticketCount.applied(to: item.ticketCount) ?? item.ticketCount
        item.priceYen = patch.priceYen.applied(to: item.priceYen)
        item.note = patch.note.applied(to: item.note) ?? ""
        item.companions = patch.companions.applied(to: item.companions) ?? item.companions
        items[index] = item
        return item
    }

    /// T2: 申込 + tour/event 付け替えをまとめて反映する（`ApplicationEditPlan`）。
    /// このフェイクは application の FK（`tourID` / `eventID`）しか持たないので、名称等の tour/event 本体は
    /// `InMemoryCatalogRepository` 側の責務。ただし `tourDraft.id` をそのまま採用すると
    /// サーバーの find-or-create（`AC-AP-07-M`）と違ってツアー名が重複してしまうため、
    /// `tourNameToID` スナップショットで「同名の既存ツアーへの吸収」だけは再現する。
    public func updateScoped(applicationID: UUID, plan: ApplicationEditPlan) async throws -> ApplicationEntry {
        var entry = try await update(id: applicationID, plan.applicationPatch)
        guard plan.tourDraft != nil || plan.eventDraft != nil else { return entry }
        if let tourDraft = plan.tourDraft {
            if let existingID = tourNameToID[tourDraft.name], existingID != tourDraft.id {
                entry.tourID = existingID
            } else {
                entry.tourID = tourDraft.id
                tourNameToID[tourDraft.name] = tourDraft.id
            }
        }
        if let eventDraft = plan.eventDraft { entry.eventID = eventDraft.id }
        if let index = items.firstIndex(where: { $0.id == applicationID }) {
            items[index] = entry
        }
        return entry
    }

    public func delete(id: UUID) async throws {
        items.removeAll { $0.id == id }
    }

    /// 名義削除の連鎖用（`InMemoryIdentityRepository.delete` から呼ばれる）。
    /// 指定した membership を代表会員として参照している application の `repMembershipID` をクリアする。
    func clearRepMembershipID(in membershipIDs: Set<UUID>) {
        guard !membershipIDs.isEmpty else { return }
        for index in items.indices {
            guard let repMembershipID = items[index].repMembershipID,
                  membershipIDs.contains(repMembershipID) else { continue }
            items[index].repMembershipID = nil
        }
    }
}

public actor InMemoryProfileRepository: ProfileRepository {
    private var snapshot: MeSnapshot

    public init(snapshot: MeSnapshot = MeSnapshot(profile: SampleData.profile, entitlement: SampleData.entitlement)) {
        self.snapshot = snapshot
    }

    public func fetchMe() async throws -> MeSnapshot { snapshot }

    public func updateMe(_ patch: ProfilePatch) async throws -> MeSnapshot {
        var profile = snapshot.profile
        profile.displayName = patch.displayName.applied(to: profile.displayName)
        profile.username = patch.username.applied(to: profile.username)
        profile.appDisplayName = patch.appDisplayName.applied(to: profile.appDisplayName)
        profile.themeColor = patch.themeColor.applied(to: profile.themeColor) ?? profile.themeColor
        profile.locale = patch.locale.applied(to: profile.locale) ?? profile.locale
        profile.timezone = patch.timezone.applied(to: profile.timezone) ?? profile.timezone
        profile.onboardedAt = patch.onboardedAt.applied(to: profile.onboardedAt)
        snapshot = MeSnapshot(profile: profile, entitlement: snapshot.entitlement)
        return snapshot
    }
}

public actor InMemoryShareRepository: ShareRepository {
    private var items: [ShareLink]

    public init(items: [ShareLink] = []) {
        self.items = items
    }

    public func list() async throws -> [ShareLink] { items }

    public func create(
        _ selection: ShareScopeSelection,
        maskMemberNo: Bool,
        sharedWithAccountIDs: [String]
    ) async throws -> IssuedShareLink {
        let now = Date()
        let link = ShareLink(
            id: UUID(),
            scopeType: selection.scopeType,
            scopeID: selection.scopeID,
            scopeName: nil,
            permission: selection.permission ?? .read,
            maskMemberNo: maskMemberNo,
            recipients: sharedWithAccountIDs.map { ShareRecipient(accountID: $0, invitedAt: now) },
            createdAt: now,
            isActive: true
        )
        items.append(link)
        return IssuedShareLink(link: link, token: "preview-token", url: "meigicho://share/preview-token")
    }

    public func addRecipients(shareID: UUID, accountIDs: [String]) async throws -> [ShareRecipient] {
        guard let index = items.firstIndex(where: { $0.id == shareID }) else { throw AppError.notFound }
        let now = Date()
        for accountID in accountIDs where !items[index].recipients.contains(where: { $0.accountID == accountID }) {
            items[index].recipients.append(ShareRecipient(accountID: accountID, invitedAt: now))
        }
        return items[index].recipients
    }

    public func removeRecipient(shareID: UUID, accountID: String) async throws {
        guard let index = items.firstIndex(where: { $0.id == shareID }) else { throw AppError.notFound }
        items[index].recipients.removeAll { $0.accountID == accountID }
    }

    public func revoke(id: UUID) async throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw AppError.notFound }
        items[index].revokedAt = Date()
        items[index].isActive = false
    }
}

public actor InMemoryAuthRepository: AuthRepository {
    public init() {}

    private func session() -> AuthSession {
        AuthSession(
            tokens: TokenPair(accessToken: "preview", refreshToken: "preview", expiresAt: Date().addingTimeInterval(3540)),
            user: SignedInUser(id: SampleData.profile.userID, accountID: SampleData.profile.accountID,
                               displayName: nil, plan: .free, isNew: false)
        )
    }

    public func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthSession { session() }
    public func signInWithGoogle(idToken: String, nonce: String?) async throws -> AuthSession { session() }
    public func register(email: String, password: String) async throws -> AuthSession { session() }
    public func login(email: String, password: String) async throws -> AuthSession { session() }
    public func changePassword(current: String, new: String) async throws -> TokenPair { session().tokens }
    public func requestPasswordReset(email: String) async throws {}
    public func resetPassword(email: String, code: String, newPassword: String) async throws -> AuthSession { session() }
    public func refresh(refreshToken: String) async throws -> TokenPair { session().tokens }
    public func logout(refreshToken: String) async throws {}
    public func deleteAccount(password: String?, appleAuthorizationCode: String?) async throws {}
}

public actor InMemorySharedBoardRepository: SharedBoardRepository {
    private var board: SharedBoard

    public init(board: SharedBoard = InMemorySharedBoardRepository.previewBoard) {
        self.board = board
    }

    public static let previewBoard = SharedBoard(
        permission: .read,
        tourName: SampleData.tours[0].name,
        artistName: SampleData.tours[0].artistNameRaw,
        generatedAt: SampleData.referenceDate,
        items: []
    )

    public func fetchBoard(shareID: UUID) async throws -> SharedBoard { board }

    public func updateItem(
        shareID: UUID,
        itemKey: String,
        rev: String,
        change: SharedItemChange
    ) async throws -> SharedBoardItem {
        guard let index = board.items.firstIndex(where: { $0.handle?.itemKey == itemKey }) else {
            throw AppError.shareInvalid
        }
        var item = board.items[index]
        if let status = change.status { item.status = status }
        if let seat = change.seat { item.seat = seat }
        board.items[index] = item
        return item
    }
}

public actor InMemorySharedInboxRepository: SharedInboxRepository {
    private var items: [SharedInboxItem]
    /// `redeem` が返す share_id。既定は 1 件目（Preview で board へ遷移できるようにする）
    private let redeemResult: UUID?

    public init(
        items: [SharedInboxItem] = InMemorySharedInboxRepository.previewItems,
        redeemResult: UUID? = nil
    ) {
        self.items = items
        self.redeemResult = redeemResult ?? items.first?.shareID
    }

    public static let previewItems: [SharedInboxItem] = [
        SharedInboxItem(
            shareID: UUID(uuidString: "018f3c2a-1111-7c90-9d2a-000000000001")!,
            scopeType: .tour,
            scopeName: SampleData.tours[0].name,
            permission: .write,
            owner: SharedInboxOwner(accountID: "ACC-7C1D02", displayName: "みお"),
            invitedAt: SampleData.referenceDate,
            expiresAt: nil,
            unread: true
        )
    ]

    public func list() async throws -> [SharedInboxItem] { items }

    public func redeem(token: String) async throws -> UUID {
        guard let redeemResult else { throw AppError.shareInvalid }
        return redeemResult
    }

    public func setHidden(shareID: UUID, hidden: Bool) async throws {
        guard hidden else { return }
        items.removeAll { $0.shareID == shareID }
    }
}

public actor InMemoryHomeRepository: HomeRepository {
    public init() {}

    public func fetchSummary() async throws -> HomeSummary {
        let today = SampleData.referenceDate
        let expiring = SampleData.memberships.compactMap(\.renewalOn).filter { renewal in
            DateFormatting.daysUntil(from: today, to: renewal) >= 0
                && DateFormatting.daysUntil(from: today, to: renewal) <= 30
        }.count
        let pending = SampleData.applications.filter { $0.status == .applied }.count
        return HomeSummary(
            identityCount: SampleData.identities.count,
            renewalsWithin30Days: expiring,
            pendingResults: pending
        )
    }
}

public actor InMemoryStatsRepository: StatsRepository {
    public init() {}

    public func fetchIdentityStats() async throws -> IdentityStatsSnapshot {
        let apps = SampleData.applications.filter { $0.status != .draft }
        var byIdentity: [UUID: (appIDs: Set<UUID>, won: Int, lost: Int, pending: Int)] = [:]

        func add(_ identityID: UUID, appID: UUID, status: ApplicationStatus) {
            var entry = byIdentity[identityID] ?? (appIDs: [], won: 0, lost: 0, pending: 0)
            let isNew = entry.appIDs.insert(appID).inserted
            guard isNew else { return }
            switch status {
            case .won: entry.won += 1
            case .lost: entry.lost += 1
            case .applied: entry.pending += 1
            default: break
            }
            byIdentity[identityID] = entry
        }

        for app in apps {
            add(app.repIdentityID, appID: app.id, status: app.status)
            for companion in app.companions {
                if let id = companion.identityID {
                    add(id, appID: app.id, status: app.status)
                }
            }
        }

        let items = byIdentity.keys.sorted { $0.uuidString < $1.uuidString }.map { id -> IdentityStatsItem in
            let entry = byIdentity[id]!
            let decided = entry.won + entry.lost
            let rate: Double? = decided == 0
                ? nil
                : (Double(entry.won) / Double(decided) * 1000).rounded() / 10
            return IdentityStatsItem(
                identityID: id,
                applicationCount: entry.appIDs.count,
                wonCount: entry.won,
                lostCount: entry.lost,
                pendingCount: entry.pending,
                winRatePercent: rate
            )
        }
        return IdentityStatsSnapshot(items: items)
    }
}

public actor InMemorySyncRepository: SyncRepository {
    public init() {}

    public func pull(_ request: SyncPullRequest) async throws -> SyncPullResult {
        SyncPullResult(changes: Dictionary(uniqueKeysWithValues: request.collections.map { ($0, []) }), nextCursor: nil, hasMore: false)
    }

    public func push(mutations: [SyncMutation]) async throws -> SyncPushResult {
        SyncPushResult(
            accepted: mutations.map(\.id),
            rejected: [],
            serverTime: SampleData.referenceDate
        )
    }
}
