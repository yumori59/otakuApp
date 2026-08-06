import Foundation
import SwiftData
import Domain

/// ローカル永続の `MembershipRepository`（`docs/05` / ios-sync-engine T3）。
/// `SwiftDataIdentityRepository` と同じ形: 呼び出しごとに `ModelContext` を作り、actor 隔離下で扱う。
public actor SwiftDataMembershipRepository: MembershipRepository {
    private let container: ModelContainer

    public init(container: ModelContainer) {
        self.container = container
    }

    public func list() async throws -> [Membership] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<MembershipRecord>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.fanClubNameRaw)]
        )
        return try context.fetch(descriptor).map { $0.toDomain() }
    }

    public func create(_ membership: Membership) async throws -> Membership {
        let context = ModelContext(container)
        if try MembershipRecord.fetchRecord(id: membership.id, in: context) != nil {
            throw AppError.conflict
        }
        // 参照先の名義が無い / 削除済みなら作らせない（BE の assertOwned 相当）。
        guard let identity = try IdentityRecord.fetchRecord(id: membership.identityID, in: context),
              identity.deletedAt == nil
        else {
            throw AppError.notFound
        }
        let record = MembershipRecord.make(from: membership)
        context.insert(record)
        OutboxQueue.enqueue(collection: .memberships, targetID: record.id, in: context)
        try context.save()
        return record.toDomain()
    }

    public func update(id: UUID, _ patch: MembershipPatch) async throws -> Membership {
        let context = ModelContext(container)
        guard let record = try MembershipRecord.fetchRecord(id: id, in: context), record.deletedAt == nil else {
            throw AppError.notFound
        }
        if case .set(let newIdentityID?) = patch.identityID {
            guard let identity = try IdentityRecord.fetchRecord(id: newIdentityID, in: context),
                  identity.deletedAt == nil
            else {
                throw AppError.notFound
            }
        }
        record.apply(patch: patch)
        OutboxQueue.enqueue(collection: .memberships, targetID: id, in: context)
        try context.save()
        return record.toDomain()
    }

    public func delete(id: UUID) async throws {
        let context = ModelContext(container)
        guard let record = try MembershipRecord.fetchRecord(id: id, in: context), record.deletedAt == nil else {
            throw AppError.notFound
        }
        record.softDelete()
        OutboxQueue.enqueue(collection: .memberships, targetID: id, in: context)
        try context.save()
    }

    /// SyncEngine / デバッグ用: pending 件数。
    public func pendingCount() async throws -> Int {
        let context = ModelContext(container)
        return try MembershipRecord.fetchPending(in: context).count
    }
}
