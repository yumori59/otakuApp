import Foundation
import SwiftData
import Domain

/// ローカル永続の `CatalogRepository`（tours + events）。
/// **作成メソッドを持たない** — tour / event はサーバー同様 `SwiftDataApplicationRepository.create` の
/// find-or-create 経由でのみ生まれる（C3 / `create-application.use-case.ts`）。
public actor SwiftDataCatalogRepository: CatalogRepository {
    private let container: ModelContainer
    /// 書き込み後の同期トリガ（`docs/05` §5「編集後3秒デバウンス」）。既定は無効。
    private let onWrite: LocalWriteObserver

    public init(container: ModelContainer, onWrite: LocalWriteObserver = .noop) {
        self.container = container
        self.onWrite = onWrite
    }

    public func listTours() async throws -> [Tour] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<TourRecord>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    public func listEvents() async throws -> [EventEntity] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<EventRecord>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.eventDate), SortDescriptor(\.name)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    public func fetchEvent(id: UUID) async throws -> EventEntity {
        let context = ModelContext(container)
        guard let record = try EventRecord.fetchRecord(id: id, in: context), record.deletedAt == nil else {
            throw AppError.notFound
        }
        return record.toDomain()
    }

    public func updateTour(id: UUID, _ patch: TourPatch) async throws -> Tour {
        let context = ModelContext(container)
        guard let record = try TourRecord.fetchRecord(id: id, in: context), record.deletedAt == nil else {
            throw AppError.notFound
        }

        let resolvedName = patch.name.applied(to: record.name) ?? record.name
        let resolvedArtistNameRaw = patch.artistNameRaw.applied(to: record.artistNameRaw) ?? ""

        // 改名時のみ同名事前チェック（D-4）。`findOrCreateTour:219-222` /
        // サーバー `sync.service.ts:367-379` と同じ「name 完全一致・deletedAt を問わない・自分以外」条件。
        if resolvedName != record.name {
            let candidateName = resolvedName
            let selfID = id
            let descriptor = FetchDescriptor<TourRecord>(
                predicate: #Predicate<TourRecord> { $0.name == candidateName && $0.id != selfID }
            )
            if try context.fetch(descriptor).first != nil {
                throw AppError.conflict
            }
        }

        // 同値保存（FR-TE-7）: 実際の差分が無ければ書き込みも outbox 追加も行わない。
        guard resolvedName != record.name || resolvedArtistNameRaw != record.artistNameRaw else {
            return record.toDomain()
        }

        record.apply(patch: patch)
        OutboxQueue.enqueue(collection: .tours, targetID: id, in: context)
        try context.save()
        onWrite.didWrite()
        return record.toDomain()
    }

    public func updateEvent(id: UUID, _ patch: EventPatch) async throws -> EventEntity {
        let context = ModelContext(container)
        guard let record = try EventRecord.fetchRecord(id: id, in: context), record.deletedAt == nil else {
            throw AppError.notFound
        }
        record.apply(patch: patch)
        OutboxQueue.enqueue(collection: .events, targetID: id, in: context)
        try context.save()
        onWrite.didWrite()
        return record.toDomain()
    }

    /// ツアー削除（D-5）: tour → 配下 event → 配下 application → 配下 companion まで、
    /// 同一 `ModelContext` / 同一 `save()` で連鎖してソフトデリートする。
    /// identity / membership は連鎖対象外（AC-TE-09）。
    public func deleteTour(id: UUID) async throws {
        let context = ModelContext(container)
        let now = Date()
        guard let tour = try TourRecord.fetchRecord(id: id, in: context), tour.deletedAt == nil else {
            throw AppError.notFound
        }

        tour.softDelete(now: now)
        OutboxQueue.enqueue(collection: .tours, targetID: tour.id, in: context, now: now)

        for event in try EventRecord.fetchActive(tourID: id, in: context) {
            event.softDelete(now: now)
            OutboxQueue.enqueue(collection: .events, targetID: event.id, in: context, now: now)

            for application in try ApplicationRecord.fetchActive(eventID: event.id, in: context) {
                try ApplicationCascadeTombstone.apply(to: application, in: context, now: now)
            }
        }

        try context.save()
        onWrite.didWrite()
    }
}
