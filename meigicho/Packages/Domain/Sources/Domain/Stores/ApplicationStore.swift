import Foundation
import Core

/// 申込 + ツアー / 公演のストア（旧 `AppDataStore` の申込側）。
///
/// `ApplicationEntry` は公演名・会場・アーティスト・公演日を持たないので、
/// **表示名は `tours` / `events` から引く**（F5・F3）。手元に無い公演は **nil を返し、空文字を作らない**。
/// 手元に無い `eventID` は `CatalogRepository.fetchEvent(id:)` で単発補完する（`contract-mapping.md` §4.6）。
@MainActor
@Observable
public final class ApplicationStore {
    public var applications: [ApplicationEntry] = []
    public var tours: [Tour] = []
    public var events: [EventEntity] = []

    public var applicationsState: LoadState = .idle
    public var catalogState: LoadState = .idle
    /// 打ち切り（E-9）。ページング上限に達したら true
    public var truncated = false
    /// 追加 / 更新の失敗。**一覧の読み込み失敗（`applicationsState`）とは別に扱う**
    public var writeError: AppError?
    /// 追加 / 更新の送信中
    public var isSaving = false

    /// 1 ページの件数。`api-contract.md` の `MAX_PAGE_LIMIT` と同じ 200
    public static let pageLimit = 200
    /// 反復の打ち切り（E-9: 200 × 20 = 4,000 件）
    public static let maxPages = 20

    private let repository: (any ApplicationRepository)?
    private let catalogRepository: (any CatalogRepository)?
    private let now: @Sendable () -> Date
    /// 単発 event 取得の重複防止
    private var pendingEventFetches: Set<UUID> = []

    public init(
        repository: (any ApplicationRepository)? = nil,
        catalogRepository: (any CatalogRepository)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.catalogRepository = catalogRepository
        self.now = now
    }

    public var today: Date { now() }

    // MARK: - 読み込み

    public func load() async {
        await loadCatalog()
        await loadApplications()
    }

    public func loadCatalog() async {
        guard let catalogRepository else { return }
        catalogState = .loading
        do {
            async let tourList = catalogRepository.listTours()
            async let eventList = catalogRepository.listEvents()
            // 失敗しても既読データは消さない（E-1 / Q11）。成功したときだけ差し替える
            let (loadedTours, loadedEvents) = try await (tourList, eventList)
            tours = loadedTours
            events = loadedEvents
            catalogState = .loaded
        } catch {
            catalogState = .failed(Self.appError(from: error))
        }
    }

    /// `has_more` が false になるまでページを辿る。
    /// **`cursor` は opaque。返ってきた `next_cursor` をそのまま次に渡すだけ**（C7）。
    /// `maxPages` に達したら打ち切って `truncated` を立てる（E-9 / AC-AP-05-T）。
    public func loadApplications() async {
        guard let repository else { return }
        applicationsState = .loading
        do {
            var collected: [ApplicationEntry] = []
            var cursor: String?
            var pages = 0
            var didTruncate = false

            while true {
                let page = try await repository.listPage(limit: Self.pageLimit, cursor: cursor)
                collected.append(contentsOf: page.items)
                pages += 1
                guard page.hasMore, let next = page.nextCursor else { break }
                if pages >= Self.maxPages {
                    didTruncate = true
                    break
                }
                cursor = next
            }

            applications = collected
            truncated = didTruncate
            applicationsState = .loaded
            await fillMissingEvents()
        } catch {
            // 既に読み込んだ内容は消さない（E-1 / AC-AP-11-M）
            applicationsState = .failed(Self.appError(from: error))
        }
    }

    /// 手元に無い公演をまとめて補完する（他端末で追加された直後など）。
    /// **失敗しても一覧をエラーにしない**（名前が「読み込み中」のまま残るだけ）。
    public func fillMissingEvents(limit: Int = 20) async {
        guard catalogRepository != nil else { return }
        var seen = Set<UUID>()
        var targets: [UUID] = []
        for id in applications.map(\.eventID) where event(for: id) == nil {
            if seen.insert(id).inserted { targets.append(id) }
            if targets.count >= limit { break }
        }
        for id in targets {
            await ensureEvent(id: id)
        }
    }

    /// 1 件だけ公演を取り直す（`GET /v1/events/:id`）。
    /// 既に手元にある / 取得中なら何もしない。
    public func ensureEvent(id: UUID) async {
        guard let catalogRepository, event(for: id) == nil, !pendingEventFetches.contains(id) else { return }
        pendingEventFetches.insert(id)
        defer { pendingEventFetches.remove(id) }
        if let fetched = try? await catalogRepository.fetchEvent(id: id) {
            upsert(event: fetched)
        }
    }

    /// ログアウト時に呼ぶ。
    ///
    /// **未ログインでもタブが見える**（Q5）ので、消さないと前のユーザーの申込がゲスト状態に残る。
    public func clear() {
        applications = []
        tours = []
        events = []
        applicationsState = .idle
        catalogState = .idle
        truncated = false
        writeError = nil
    }

    static func appError(from error: Error) -> AppError {
        if let appError = error as? AppError { return appError }
        if let urlError = error as? URLError { return AppError.from(urlError: urlError) }
        return .unknown(code: "UNEXPECTED", message: nil)
    }

    // MARK: - 参照（join）

    public func application(for id: UUID) -> ApplicationEntry? {
        applications.first { $0.id == id }
    }

    public func tour(for id: UUID) -> Tour? {
        tours.first { $0.id == id }
    }

    public func event(for id: UUID) -> EventEntity? {
        events.first { $0.id == id }
    }

    /// 手元に対応する公演が無ければ nil（空文字を作らない）。
    public func eventName(for app: ApplicationEntry) -> String? {
        event(for: app.eventID)?.name
    }

    public func venueName(for app: ApplicationEntry) -> String? {
        event(for: app.eventID)?.venueNameRaw
    }

    public func eventDate(for app: ApplicationEntry) -> Date? {
        event(for: app.eventID)?.eventDate
    }

    public func tourName(for app: ApplicationEntry) -> String? {
        tour(for: app.tourID)?.name
    }

    public func artistName(for app: ApplicationEntry) -> String? {
        tour(for: app.tourID)?.artistNameRaw
    }

    /// 表示用の解決結果をまとめて返す（View 側での多重 lookup を避ける）。
    public func display(for app: ApplicationEntry) -> ApplicationDisplay {
        ApplicationDisplay(
            eventName: eventName(for: app),
            venueName: venueName(for: app),
            artistName: artistName(for: app),
            tourName: tourName(for: app),
            eventDate: eventDate(for: app)
        )
    }

    // MARK: - 集計

    public func applications(for identityID: UUID) -> [ApplicationEntry] {
        applications.filter { app in
            app.repIdentityID == identityID ||
            app.companions.contains { $0.identityID == identityID }
        }
    }

    public func winCount(for identityID: UUID) -> Int {
        applications(for: identityID).filter { $0.status == .won }.count
    }

    /// 名義 ID → 当選数。`IdentityStore.sortedIdentities(by:winCounts:)` に渡す。
    public func winCounts() -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for app in applications where app.status == .won {
            result[app.repIdentityID, default: 0] += 1
            for companion in app.companions {
                if let id = companion.identityID {
                    result[id, default: 0] += 1
                }
            }
        }
        return result
    }

    public func pendingResultCount() -> Int {
        applications.filter { $0.status == .applied }.count
    }

    /// 当選済みで公演日が未来のもの。**公演日が不明な申込は出さない**（E-8）。
    public func upcomingWonEvents(limit: Int = 5) -> [ApplicationEntry] {
        let today = now()
        return applications
            .filter { app in
                guard app.status == .won, let date = eventDate(for: app) else { return false }
                return DateFormatting.daysUntil(from: today, to: date) >= 0
            }
            .sorted { (eventDate(for: $0) ?? .distantFuture) < (eventDate(for: $1) ?? .distantFuture) }
            .prefix(limit)
            .map { $0 }
    }

    public func awaitingResults(limit: Int = 4) -> [ApplicationEntry] {
        applications
            .filter { $0.status == .applied }
            .sorted { ($0.resultOn ?? .distantFuture) < ($1.resultOn ?? .distantFuture) }
            .prefix(limit)
            .map { $0 }
    }

    /// 絞り込み + 検索。公演日 昇順・**公演日不明は末尾**（E-8）。
    public func filteredApplications(filter: ApplicationFilter, search: String) -> [ApplicationEntry] {
        var result = applications
        switch filter {
        case .all: break
        case .draft: result = result.filter { $0.status == .draft }
        case .applied: result = result.filter { $0.status == .applied }
        case .won: result = result.filter { $0.status == .won }
        case .lost: result = result.filter { $0.status == .lost }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { app in
                let d = display(for: app)
                return [d.eventName, d.artistName, d.venueName, d.tourName]
                    .compactMap { $0 }
                    .contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }
        return sortedByEventDate(result)
    }

    public func sortedByEventDate(_ apps: [ApplicationEntry]) -> [ApplicationEntry] {
        apps.sorted { lhs, rhs in
            switch (eventDate(for: lhs), eventDate(for: rhs)) {
            case (let l?, let r?): return l < r
            case (nil, _?): return false      // 公演日不明は末尾
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }
    }

    // MARK: - ツアーごとのグルーピング（キーは tourID = F5）

    public struct TourGroup: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let tour: Tour
        public let items: [ApplicationEntry]

        public init(id: UUID, tour: Tour, items: [ApplicationEntry]) {
            self.id = id
            self.tour = tour
            self.items = items
        }

        public var tourName: String { tour.name }
    }

    public func groupedByTour(filter: ApplicationFilter, search: String) -> [TourGroup] {
        groupApplications(filteredApplications(filter: filter, search: search))
    }

    public func allTourGroups() -> [TourGroup] {
        groupApplications(applications)
    }

    public var existingTourNames: [String] {
        Array(Set(tours.map(\.name))).sorted()
    }

    private func groupApplications(_ apps: [ApplicationEntry]) -> [TourGroup] {
        var map: [UUID: [ApplicationEntry]] = [:]
        for app in apps {
            map[app.tourID, default: []].append(app)
        }
        return map.compactMap { tourID, items -> TourGroup? in
            guard let tour = tour(for: tourID) else { return nil }
            return TourGroup(id: tourID, tour: tour, items: sortedByEventDate(items))
        }
        .sorted { lhs, rhs in
            let l = lhs.items.first.flatMap { eventDate(for: $0) } ?? .distantFuture
            let r = rhs.items.first.flatMap { eventDate(for: $0) } ?? .distantFuture
            if l == r { return lhs.tour.name < rhs.tour.name }
            return l < r
        }
    }

    // MARK: - 更新

    public func clearWriteError() {
        writeError = nil
    }

    /// 申込を追加する。
    ///
    /// ツアー / 公演は **`POST /v1/applications` の find-or-create でしか作れない**（`POST /v1/tours` は無い = C3）。
    /// サーバーは tour を `(owner, name)` で照合するため、**返ってきた `tour_id` は送った id と異なりうる**。
    /// 手元のカタログはレスポンスの id を正として揃える（AC-AP-07-M）。
    ///
    /// 失敗時は `nil` を返し、`writeError` に理由を入れる（**楽観追加してから巻き戻さない**。
    /// フォームは開いたままでエラーを出す）。
    @discardableResult
    public func addApplication(_ draft: ApplicationDraft) async -> ApplicationEntry? {
        let normalized = Self.normalizedDraft(draft)
        guard let repository else {
            // Preview / テスト（ネットワーク未接続）: ローカルだけで完結させる
            return applyLocally(normalized)
        }
        writeError = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let entry = try await repository.create(normalized)
            reconcileCatalog(with: entry, draft: normalized)
            upsert(application: entry)
            return entry
        } catch {
            writeError = Self.appError(from: error)
            return nil
        }
    }

    /// ステータス変更。**`status` だけを送る**ので、落選に戻しても座席は消えない（AC-AP-08-M / `docs/05` R3-3）。
    public func updateApplicationStatus(_ id: UUID, status: ApplicationStatus) async {
        var patch = ApplicationPatch()
        patch.status = .set(status)
        await applyOptimistic(id: id, patch: patch) { $0.status = status }
    }

    /// 座席のインライン編集。空文字は **`null` を送ってクリア**する（§1.2）。
    public func updateApplicationSeat(_ id: UUID, seat: String) async {
        let trimmed = seat.trimmingCharacters(in: .whitespacesAndNewlines)
        var patch = ApplicationPatch()
        patch.seatRaw = trimmed.isEmpty ? .set(nil) : .set(trimmed)
        await applyOptimistic(id: id, patch: patch) { $0.seatRaw = trimmed }
    }

    /// 申込編集（T5 の編集フォームから呼ばれる想定）。
    ///
    /// 差分計算は `ApplicationEditPlanner.makePlan`（純粋関数・T1）に委ね、Store は
    /// 「現在値の取得 → plan 組み立て → `updateScoped` 呼び出し → ローカル反映」の配線だけを持つ
    /// （`updateApplicationStatus` / `updateApplicationSeat` と同じ「Store が差分を組み立てる」パターン）。
    ///
    /// **楽観更新はしない**（D-5）。申込 + 公演 + ツアーにまたがる変更を後付け undo で巻き戻すと
    /// 途中状態が残りうる（IOS-13）。保存中は `isSaving`、成功したらリポジトリの戻り値をそのまま
    /// 反映し、失敗したら `writeError` を立てて何も書き換えない（`addApplication` と同じ方針）。
    @discardableResult
    public func updateApplication(_ id: UUID, input: ApplicationEditFormInput) async -> ApplicationEntry? {
        guard let current = application(for: id),
              let currentTour = tour(for: current.tourID),
              let currentEvent = event(for: current.eventID)
        else {
            writeError = .notFound
            return nil
        }

        let plan = ApplicationEditPlanner.makePlan(
            current: current,
            currentTour: currentTour,
            currentEvent: currentEvent,
            input: input
        )

        guard let repository else {
            // Preview / テスト（ネットワーク未接続）: ローカルだけで完結させる
            return applyEditLocally(id: id, plan: plan)
        }
        writeError = nil
        isSaving = true
        defer { isSaving = false }
        do {
            let entry = try await repository.updateScoped(applicationID: id, plan: plan)
            reconcileEditedCatalog(with: entry, plan: plan)
            upsert(application: entry)
            return entry
        } catch {
            writeError = Self.appError(from: error)
            return nil
        }
    }

    /// 楽観更新 → PATCH → 成功ならサーバーの値で置換 / 失敗なら巻き戻す。
    private func applyOptimistic(
        id: UUID,
        patch: ApplicationPatch,
        mutate: (inout ApplicationEntry) -> Void
    ) async {
        guard let index = applications.firstIndex(where: { $0.id == id }) else { return }
        let previous = applications[index]
        var optimistic = previous
        mutate(&optimistic)
        applications[index] = optimistic

        guard let repository else { return }
        writeError = nil
        isSaving = true
        defer { isSaving = false }
        do {
            // E-4: サーバーが `rep_membership_id` を自動クリアすることがあるため、
            // レスポンスをそのまま反映する（手元の値で上書きしない）
            let updated = try await repository.update(id: id, patch)
            upsert(application: updated)
        } catch {
            writeError = Self.appError(from: error)
            // UI の値を巻き戻す
            if let current = applications.firstIndex(where: { $0.id == id }) {
                applications[current] = previous
            }
        }
    }

    // MARK: - ローカル反映

    /// `companions` を送信可能な形にそろえる（0〜3 件 / `identity_id` 重複除去 / `position` は 0 起点連番）。
    /// AC-AP-02-T・AC-AP-03-T。**Network 側でも同じ正規化をする**（多重防御）。
    public static func normalizedDraft(_ draft: ApplicationDraft) -> ApplicationDraft {
        var result = draft
        result.companions = normalizedCompanions(draft.companions)
        // FR-AP-7 / AC-AP-12: 会員情報連携は今回スコープ外。**常に nil**
        result.repMembershipID = nil
        return result
    }

    public static func normalizedCompanions(_ companions: [Companion]) -> [Companion] {
        CompanionNormalizer.normalize(companions)
    }

    /// `api-contract.md` §7「companions は 0〜3 件」
    public static let maxCompanions = CompanionNormalizer.maxCompanions

    private func upsert(application entry: ApplicationEntry) {
        if let index = applications.firstIndex(where: { $0.id == entry.id }) {
            applications[index] = entry
        } else {
            applications.append(entry)
        }
    }

    private func upsert(event entity: EventEntity) {
        if let index = events.firstIndex(where: { $0.id == entity.id }) {
            events[index] = entity
        } else {
            events.append(entity)
        }
    }

    private func upsert(tour: Tour) {
        if let index = tours.firstIndex(where: { $0.id == tour.id }) {
            tours[index] = tour
        } else {
            tours.append(tour)
        }
    }

    /// `updateApplication` の戻り値でカタログを揃える。`addApplication` の `reconcileCatalog` と違い、
    /// 編集は**現地更新**（同じ id を上書き）もありうるので `upsert`（無ければ追加・あれば置換）を使う。
    ///
    /// `entry.tourID` はサーバーの find-or-create の結果なので、`plan.tourDraft.id`（編集前の文脈から
    /// 計算した付け替え候補の id）と一致しないことがある＝**既存の別ツアーに吸収された**。
    /// その場合 `tourDraft.artistNameRaw` は吸収先ツアーの実際の値とは無関係なので上書きしない
    /// （吸収先の既存 `artistNameRaw` を保持する）。一致する場合だけ「同一ツアーの現地更新」として反映する。
    private func reconcileEditedCatalog(with entry: ApplicationEntry, plan: ApplicationEditPlan) {
        if let tourDraft = plan.tourDraft {
            if let existingTour = tour(for: entry.tourID) {
                let artistNameRaw = entry.tourID == tourDraft.id
                    ? tourDraft.artistNameRaw
                    : existingTour.artistNameRaw
                upsert(tour: Tour(
                    id: entry.tourID,
                    name: tourDraft.name,
                    artistNameRaw: artistNameRaw,
                    updatedAt: now()
                ))
            } else {
                tours.append(Tour(
                    id: entry.tourID,
                    name: tourDraft.name,
                    artistNameRaw: tourDraft.artistNameRaw,
                    updatedAt: now()
                ))
            }
        }
        if let eventDraft = plan.eventDraft {
            upsert(event: EventEntity(
                id: entry.eventID,
                tourID: entry.tourID,
                name: eventDraft.name,
                venueNameRaw: eventDraft.venueNameRaw,
                eventDate: eventDraft.eventDate,
                startsAt: eventDraft.startsAt,
                updatedAt: now()
            ))
        }
    }

    /// ネットワーク未接続時（Preview / テスト）のローカル編集反映。
    @discardableResult
    private func applyEditLocally(id: UUID, plan: ApplicationEditPlan) -> ApplicationEntry? {
        guard let index = applications.firstIndex(where: { $0.id == id }) else {
            writeError = .notFound
            return nil
        }
        var entry = applications[index]
        let patch = plan.applicationPatch
        entry.repIdentityID = patch.repIdentityID.applied(to: entry.repIdentityID) ?? entry.repIdentityID
        entry.repMembershipID = patch.repMembershipID.applied(to: entry.repMembershipID)
        entry.roundName = patch.roundName.applied(to: entry.roundName)
        entry.appliedOn = patch.appliedOn.applied(to: entry.appliedOn)
        entry.resultOn = patch.resultOn.applied(to: entry.resultOn)
        entry.status = patch.status.applied(to: entry.status) ?? entry.status
        entry.seatRaw = patch.seatRaw.applied(to: entry.seatRaw) ?? entry.seatRaw
        entry.ticketCount = patch.ticketCount.applied(to: entry.ticketCount) ?? entry.ticketCount
        entry.priceYen = patch.priceYen.applied(to: entry.priceYen)
        entry.note = patch.note.applied(to: entry.note) ?? ""
        entry.companions = patch.companions.applied(to: entry.companions) ?? entry.companions
        if let tourDraft = plan.tourDraft {
            // `tourDraft.id != entry.tourID`（＝ツアー名変更で新規 id を発行した）ときだけ、
            // サーバーの find-or-create と同じく**ツアー名の一致で既存ツアーに吸収**する（`applyLocally` と同じ設計）。
            // 一致しなければ本当に新規ツアーとして `tourDraft.id` を使う（`reconcileEditedCatalog` が append する）。
            if tourDraft.id != entry.tourID, let existing = tours.first(where: { $0.name == tourDraft.name }) {
                entry.tourID = existing.id
            } else {
                entry.tourID = tourDraft.id
            }
        }
        if let eventDraft = plan.eventDraft { entry.eventID = eventDraft.id }
        applications[index] = entry
        reconcileEditedCatalog(with: entry, plan: plan)
        return entry
    }

    /// サーバーが確定させた `tour_id` / `event_id` に手元のカタログを合わせる。
    /// 既存ツアーに吸収された場合は**ツアーが増えない**（AC-AP-07-M）。
    private func reconcileCatalog(with entry: ApplicationEntry, draft: ApplicationDraft) {
        if tour(for: entry.tourID) == nil {
            tours.append(
                Tour(
                    id: entry.tourID,
                    name: draft.tour.name,
                    artistNameRaw: draft.tour.artistNameRaw,
                    updatedAt: now()
                )
            )
        }
        if event(for: entry.eventID) == nil {
            events.append(
                EventEntity(
                    id: entry.eventID,
                    tourID: entry.tourID,
                    name: draft.event.name,
                    venueNameRaw: draft.event.venueNameRaw,
                    eventDate: draft.event.eventDate,
                    startsAt: draft.event.startsAt,
                    updatedAt: now()
                )
            )
        }
    }

    /// ネットワーク未接続時（Preview / テスト）のローカル追加。
    /// サーバーの find-or-create と同じく**ツアー名の一致で再利用**する。
    @discardableResult
    private func applyLocally(_ draft: ApplicationDraft) -> ApplicationEntry {
        let tourID: UUID
        if let existing = tours.first(where: { $0.name == draft.tour.name }) {
            tourID = existing.id
        } else {
            tourID = draft.tour.id
            tours.append(
                Tour(id: tourID, name: draft.tour.name, artistNameRaw: draft.tour.artistNameRaw, updatedAt: now())
            )
        }

        let event = EventEntity(
            id: draft.event.id,
            tourID: tourID,
            name: draft.event.name,
            venueNameRaw: draft.event.venueNameRaw,
            eventDate: draft.event.eventDate,
            startsAt: draft.event.startsAt,
            updatedAt: now()
        )
        events.append(event)

        let entry = ApplicationEntry(
            id: draft.id,
            tourID: tourID,
            eventID: event.id,
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
            note: draft.note,
            updatedAt: now()
        )
        applications.append(entry)
        return entry
    }

    // MARK: - 重複申込（`docs/01` R2-8）

    public func duplicateEventIDs() -> Set<UUID> {
        DuplicateApplicationDetection.duplicateEventIDs(in: applications)
    }

    public func isDuplicateEvent(_ application: ApplicationEntry) -> Bool {
        duplicateEventIDs().contains(application.eventID)
    }

    public func coApplications(for eventID: UUID) -> [ApplicationEntry] {
        DuplicateApplicationDetection.coApplications(for: eventID, in: applications)
    }
}

/// 申込 1 件の表示用に解決した値。**未解決は nil のまま**（空文字を作らない）。
public struct ApplicationDisplay: Equatable, Sendable {
    public let eventName: String?
    public let venueName: String?
    public let artistName: String?
    public let tourName: String?
    public let eventDate: Date?

    public init(eventName: String?, venueName: String?, artistName: String?, tourName: String?, eventDate: Date?) {
        self.eventName = eventName
        self.venueName = venueName
        self.artistName = artistName
        self.tourName = tourName
        self.eventDate = eventDate
    }
}
