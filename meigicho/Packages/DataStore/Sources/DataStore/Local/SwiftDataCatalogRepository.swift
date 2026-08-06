import Foundation
import SwiftData
import Domain

/// ローカル永続の `CatalogRepository`（tours + events）。
/// **作成メソッドを持たない** — tour / event はサーバー同様 `SwiftDataApplicationRepository.create` の
/// find-or-create 経由でのみ生まれる（C3 / `create-application.use-case.ts`）。
public actor SwiftDataCatalogRepository: CatalogRepository {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
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
        record.apply(patch: patch)
        OutboxQueue.enqueue(collection: .tours, targetID: id, in: context)
        try context.save()
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
        return record.toDomain()
    }
}
