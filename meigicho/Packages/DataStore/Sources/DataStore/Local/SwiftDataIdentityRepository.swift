import Foundation
import SwiftData
import Domain

/// ローカル永続の `IdentityRepository`（`docs/05` / ios-sync-engine T1）。
/// 呼び出しごとに `ModelContext` を作り、actor 隔離下で SwiftData を扱う。
public actor SwiftDataIdentityRepository: IdentityRepository {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func list() async throws -> [Identity] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<IdentityRecord>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.displayName)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    public func create(_ identity: Identity) async throws -> Identity {
        let context = ModelContext(container)
        let existing = try fetchRecord(id: identity.id, in: context)
        if existing != nil {
            throw AppError.conflict
        }
        let record = IdentityRecord.make(from: identity, syncState: .pendingCreate)
        context.insert(record)
        enqueueOutbox(targetID: identity.id, in: context)
        try context.save()
        return record.toDomain()
    }

    public func update(id: UUID, _ patch: IdentityPatch) async throws -> Identity {
        let context = ModelContext(container)
        guard let record = try fetchRecord(id: id, in: context), record.deletedAt == nil else {
            throw AppError.notFound
        }
        record.apply(patch: patch)
        enqueueOutbox(targetID: id, in: context)
        try context.save()
        return record.toDomain()
    }

    public func delete(id: UUID) async throws {
        let context = ModelContext(container)
        guard let record = try fetchRecord(id: id, in: context), record.deletedAt == nil else {
            throw AppError.notFound
        }
        record.softDelete()
        enqueueOutbox(targetID: id, in: context)
        try context.save()
    }

    /// SyncEngine 用: pending 件数。
    public func pendingCount() async throws -> Int {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<IdentityRecord>(
            predicate: #Predicate { $0.syncStateRaw != 0 }
        )
        return try context.fetch(descriptor).count
    }

    private func enqueueOutbox(targetID: UUID, in context: ModelContext) {
        let descriptor = FetchDescriptor<OutboxEntry>(
            predicate: #Predicate { $0.targetID == targetID }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.enqueuedAt = Date()
            existing.attemptCount = 0
            existing.lastError = nil
            existing.nextRetryAt = nil
            return
        }
        context.insert(OutboxEntry(collection: .identities, targetID: targetID))
    }

    private func fetchRecord(id: UUID, in context: ModelContext) throws -> IdentityRecord? {
        let descriptor = FetchDescriptor<IdentityRecord>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }
}
