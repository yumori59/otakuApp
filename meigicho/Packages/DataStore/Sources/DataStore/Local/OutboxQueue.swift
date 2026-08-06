import Foundation
import SwiftData
import Domain

/// Outbox（送信キュー）の共通操作。ペイロードは持たず、対象行の現在値を push 時に読む（`docs/05` §5）。
public enum OutboxQueue {
    public static func enqueue(
        collection: SyncCollection,
        targetID: UUID,
        in context: ModelContext,
        now: Date = Date()
    ) {
        let descriptor = FetchDescriptor<OutboxEntry>(
            predicate: #Predicate { $0.targetID == targetID }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.enqueuedAt = now
            existing.attemptCount = 0
            existing.lastError = nil
            existing.nextRetryAt = nil
            return
        }
        context.insert(OutboxEntry(collection: collection, targetID: targetID, enqueuedAt: now))
    }

    public static func remove(targetID: UUID, in context: ModelContext) throws {
        let descriptor = FetchDescriptor<OutboxEntry>(
            predicate: #Predicate { $0.targetID == targetID }
        )
        for entry in try context.fetch(descriptor) {
            context.delete(entry)
        }
    }

    /// push が受理されなかった行の記録。次サイクルで再送する（行は残す）。
    public static func recordFailure(
        targetID: UUID,
        message: String,
        in context: ModelContext,
        now: Date = Date()
    ) throws {
        let descriptor = FetchDescriptor<OutboxEntry>(
            predicate: #Predicate { $0.targetID == targetID }
        )
        for entry in try context.fetch(descriptor) {
            entry.attemptCount += 1
            entry.lastError = message
            entry.nextRetryAt = now.addingTimeInterval(min(300, pow(2, Double(entry.attemptCount))))
        }
    }
}
