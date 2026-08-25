import Foundation
import SwiftData
import Domain

/// 「申込本体 + 配下 companions を softDelete して outbox へ enqueue する」処理の共通ヘルパ。
///
/// `SwiftDataApplicationRepository.delete(id:)`（申込単体の削除）と
/// `SwiftDataCatalogRepository.deleteTour(id:)`（ツアー削除の連鎖・`tour-edit-and-delete` D-5）の
/// 2 箇所から同一内容で呼ばれる。書き込み経路が増えても後始末が片方だけにならないよう
/// 一本化する（`feedback_review_patterns.md` BE-9）。
///
/// `context.save()` は呼ばない — 呼び出し元がまとめて 1 回だけ呼ぶ。
enum ApplicationCascadeTombstone {
    static func apply(to record: ApplicationRecord, in context: ModelContext, now: Date) throws {
        record.softDelete(now: now)
        OutboxQueue.enqueue(collection: .applications, targetID: record.id, in: context, now: now)

        for companion in try ApplicationCompanionRecord.fetchActive(applicationID: record.id, in: context) {
            companion.softDelete(now: now)
            OutboxQueue.enqueue(collection: .applicationCompanions, targetID: companion.id, in: context, now: now)
        }
    }
}
