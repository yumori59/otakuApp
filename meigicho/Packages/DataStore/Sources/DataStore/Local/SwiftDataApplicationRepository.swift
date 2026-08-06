import Foundation
import SwiftData
import Domain
import Core

/// ローカル永続の `ApplicationRepository`。
///
/// `create` は BE の `POST /v1/applications`（`create-application.use-case.ts`）と同じ手順を踏む:
/// tour find-or-create（name 一致・ソフトデリートは復活） → event upsert（id） → 所有検証 → 作成。
/// companions は最大 `ApplicationCompanionRecord.maxPerApplication` 件・`identity_id` 重複不可（E-7）。
public actor SwiftDataApplicationRepository: ApplicationRepository {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Read

    /// `updated_at` asc, `id` asc + 不透明カーソル（BE の `applications.service.ts` と同じ並び）。
    public func listPage(limit: Int, cursor: String?) async throws -> ApplicationPage {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ApplicationRecord>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt), SortDescriptor(\.id)]
        )
        var rows = try context.fetch(descriptor)

        if let cursor, !cursor.isEmpty {
            let parsed = try Self.parseCursor(cursor)
            rows = rows.filter { row in
                row.updatedAt > parsed.updatedAt
                    || (row.updatedAt == parsed.updatedAt && row.id.uuidString > parsed.id.uuidString)
            }
        }

        let hasMore = rows.count > limit
        let page = hasMore ? Array(rows.prefix(limit)) : rows
        var items: [ApplicationEntry] = []
        for record in page {
            if let entry = try toDomain(record, in: context) {
                items.append(entry)
            }
        }
        let last = page.last

        return ApplicationPage(
            items: items,
            nextCursor: last.map { Self.formatCursor(updatedAt: $0.updatedAt, id: $0.id) },
            hasMore: hasMore
        )
    }

    // MARK: - Write

    public func create(_ draft: ApplicationDraft) async throws -> ApplicationEntry {
        let context = ModelContext(container)
        let now = Date()

        if try ApplicationRecord.fetchRecord(id: draft.id, in: context) != nil {
            throw AppError.conflict
        }
        let companions = try Self.normalizeCompanions(draft.companions)

        let tour = try findOrCreateTour(draft.tour, in: context, now: now)
        let event = try upsertEvent(draft.event, tourID: tour.id, in: context, now: now)
        try assertIdentityOwned(draft.repIdentityID, in: context)
        if let membershipID = draft.repMembershipID {
            try assertMembershipOwned(membershipID, identityID: draft.repIdentityID, in: context)
        }
        for companion in companions {
            if let identityID = companion.identityID {
                try assertIdentityOwned(identityID, in: context)
            }
        }

        let record = ApplicationRecord.make(from: draft, eventID: event.id, now: now)
        context.insert(record)
        OutboxQueue.enqueue(collection: .applications, targetID: record.id, in: context, now: now)

        for companion in companions {
            let companionRecord = ApplicationCompanionRecord.make(from: companion, applicationID: record.id, now: now)
            context.insert(companionRecord)
            OutboxQueue.enqueue(collection: .applicationCompanions, targetID: companionRecord.id, in: context, now: now)
        }

        try context.save()
        guard let entry = try toDomain(record, in: context) else { throw AppError.notFound }
        return entry
    }

    public func update(id: UUID, _ patch: ApplicationPatch) async throws -> ApplicationEntry {
        let context = ModelContext(container)
        let now = Date()

        guard let record = try ApplicationRecord.fetchRecord(id: id, in: context), record.deletedAt == nil else {
            throw AppError.notFound
        }

        let nextIdentityID = patch.repIdentityID.applied(to: record.repIdentityID) ?? record.repIdentityID
        if case .set = patch.repIdentityID {
            try assertIdentityOwned(nextIdentityID, in: context)
        }
        if let membershipID = patch.repMembershipID.applied(to: record.repMembershipID) {
            let membership = try MembershipRecord.fetchRecord(id: membershipID, in: context)
            let stillValid = membership.map { $0.deletedAt == nil && $0.identityID == nextIdentityID } ?? false
            if !stillValid {
                if case .set = patch.repMembershipID {
                    // 明示指定が不正なら 404 相当（BE `assertMembershipOwned`）
                    throw AppError.notFound
                }
                // 代表名義の変更で属さなくなった既存値は自動クリア（BE `findMembershipOwned`）
                record.repMembershipID = nil
            }
        }

        record.apply(patch: patch, now: now)

        // companions は `.set` のときだけ全置換。`.unchanged` なら一切触らない（AC-APP-12）。
        if case .set(let incoming) = patch.companions {
            let normalized = try Self.normalizeCompanions(incoming ?? [])
            for companion in normalized {
                if let identityID = companion.identityID {
                    try assertIdentityOwned(identityID, in: context)
                }
            }
            try replaceCompanions(normalized, applicationID: record.id, in: context, now: now)
        }

        OutboxQueue.enqueue(collection: .applications, targetID: record.id, in: context, now: now)
        try context.save()
        guard let entry = try toDomain(record, in: context) else { throw AppError.notFound }
        return entry
    }

    /// 申込と配下 companions をソフトデリート（BE `remove` と同じ）。
    public func delete(id: UUID) async throws {
        let context = ModelContext(container)
        let now = Date()
        guard let record = try ApplicationRecord.fetchRecord(id: id, in: context), record.deletedAt == nil else {
            throw AppError.notFound
        }
        record.softDelete(now: now)
        OutboxQueue.enqueue(collection: .applications, targetID: record.id, in: context, now: now)

        for companion in try ApplicationCompanionRecord.fetchActive(applicationID: id, in: context) {
            companion.softDelete(now: now)
            OutboxQueue.enqueue(collection: .applicationCompanions, targetID: companion.id, in: context, now: now)
        }
        try context.save()
    }

    public func pendingCount() async throws -> Int {
        let context = ModelContext(container)
        return try ApplicationRecord.fetchPending(in: context).count
            + ApplicationCompanionRecord.fetchPending(in: context).count
    }

    // MARK: - find-or-create / upsert

    private func findOrCreateTour(_ draft: TourDraft, in context: ModelContext, now: Date) throws -> TourRecord {
        let name = draft.name
        let descriptor = FetchDescriptor<TourRecord>(
            predicate: #Predicate { $0.name == name }
        )
        if let existing = try context.fetch(descriptor).first {
            if existing.deletedAt != nil {
                existing.deletedAt = nil
                if !draft.artistNameRaw.isEmpty {
                    existing.artistNameRaw = draft.artistNameRaw
                }
                existing.markDirty(now: now)
                OutboxQueue.enqueue(collection: .tours, targetID: existing.id, in: context, now: now)
            }
            return existing
        }

        let record = TourRecord(
            id: draft.id,
            name: draft.name,
            artistNameRaw: draft.artistNameRaw,
            updatedAt: now,
            syncState: .pendingCreate
        )
        context.insert(record)
        OutboxQueue.enqueue(collection: .tours, targetID: record.id, in: context, now: now)
        return record
    }

    private func upsertEvent(_ draft: EventDraft, tourID: UUID, in context: ModelContext, now: Date) throws -> EventRecord {
        if let existing = try EventRecord.fetchRecord(id: draft.id, in: context) {
            existing.tourID = tourID
            existing.name = draft.name
            existing.venueNameRaw = draft.venueNameRaw
            existing.eventDate = draft.eventDate
            existing.startsAt = draft.startsAt
            existing.deletedAt = nil
            existing.markDirty(now: now)
            OutboxQueue.enqueue(collection: .events, targetID: existing.id, in: context, now: now)
            return existing
        }

        let record = EventRecord(
            id: draft.id,
            tourID: tourID,
            name: draft.name,
            venueNameRaw: draft.venueNameRaw,
            eventDate: draft.eventDate,
            startsAt: draft.startsAt,
            updatedAt: now,
            syncState: .pendingCreate
        )
        context.insert(record)
        OutboxQueue.enqueue(collection: .events, targetID: record.id, in: context, now: now)
        return record
    }

    /// 全置換。消えた行はソフトデリート、残った行は更新、新規は insert（`applications.service.ts` と同じ）。
    private func replaceCompanions(
        _ incoming: [Companion],
        applicationID: UUID,
        in context: ModelContext,
        now: Date
    ) throws {
        let existing = try ApplicationCompanionRecord.fetchAll(applicationID: applicationID, in: context)
        let incomingIDs = Set(incoming.map(\.id))

        for record in existing where record.deletedAt == nil && !incomingIDs.contains(record.id) {
            record.softDelete(now: now)
            OutboxQueue.enqueue(collection: .applicationCompanions, targetID: record.id, in: context, now: now)
        }

        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for companion in incoming {
            if let record = existingByID[companion.id] {
                record.apply(companion: companion, now: now)
                OutboxQueue.enqueue(collection: .applicationCompanions, targetID: record.id, in: context, now: now)
            } else {
                let record = ApplicationCompanionRecord.make(from: companion, applicationID: applicationID, now: now)
                context.insert(record)
                OutboxQueue.enqueue(collection: .applicationCompanions, targetID: record.id, in: context, now: now)
            }
        }
    }

    // MARK: - Validation

    private func assertIdentityOwned(_ id: UUID, in context: ModelContext) throws {
        guard let identity = try IdentityRecord.fetchRecord(id: id, in: context), identity.deletedAt == nil else {
            throw AppError.notFound
        }
    }

    private func assertMembershipOwned(_ id: UUID, identityID: UUID, in context: ModelContext) throws {
        guard let membership = try MembershipRecord.fetchRecord(id: id, in: context),
              membership.deletedAt == nil,
              membership.identityID == identityID
        else {
            throw AppError.notFound
        }
    }

    /// 件数上限・`identity_id` 重複を弾き、`position` を 0 起点連番に振り直す（`api-contract.md` §7 / E-7）。
    static func normalizeCompanions(_ companions: [Companion]) throws -> [Companion] {
        guard companions.count <= ApplicationCompanionRecord.maxPerApplication else {
            throw AppError.validation(message: "同行者は\(ApplicationCompanionRecord.maxPerApplication)人までです")
        }
        let identityIDs = companions.compactMap(\.identityID)
        guard Set(identityIDs).count == identityIDs.count else {
            throw AppError.validation(message: "同行者の名義が重複しています")
        }
        return companions
            .sorted { $0.position < $1.position }
            .enumerated()
            .map { index, companion in
                Companion(
                    id: companion.id,
                    identityID: companion.identityID,
                    displayName: companion.displayName,
                    position: index
                )
            }
    }

    // MARK: - Mapping

    /// event が未取得のローカル行は Domain 値を組めないので取りこぼす（次の pull で埋まる）。
    private func toDomain(_ record: ApplicationRecord, in context: ModelContext) throws -> ApplicationEntry? {
        guard let event = try EventRecord.fetchRecord(id: record.eventID, in: context) else { return nil }
        let companions = try ApplicationCompanionRecord
            .fetchActive(applicationID: record.id, in: context)
            .map { $0.toDomain() }
        return record.toDomain(tourID: event.tourID, companions: companions)
    }

    // MARK: - Cursor（不透明。BE と同じ `"<iso>|<uuid>"` 形式）

    private static let cursorSeparator = "|"

    static func formatCursor(updatedAt: Date, id: UUID) -> String {
        "\(APIDateFormat.dateTimeString(from: updatedAt))\(cursorSeparator)\(id.uuidString.lowercased())"
    }

    static func parseCursor(_ raw: String) throws -> (updatedAt: Date, id: UUID) {
        let parts = raw.split(separator: Character(cursorSeparator), maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let updatedAt = APIDateFormat.dateTime(from: String(parts[0])),
              let id = UUID(uuidString: String(parts[1]))
        else {
            throw AppError.validation(message: "invalid cursor")
        }
        return (updatedAt, id)
    }
}
