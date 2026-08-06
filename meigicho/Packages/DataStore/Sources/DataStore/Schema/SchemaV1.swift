import Foundation
import SwiftData

/// Schema V1 — `docs/04` §4 の同期対象 6 コレクション + Outbox。
/// 出荷前のためバージョンは V1 のまま拡張する（マイグレーション段階なし / ios-sync-engine T3）。
public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            IdentityRecord.self,
            MembershipRecord.self,
            TourRecord.self,
            EventRecord.self,
            ApplicationRecord.self,
            ApplicationCompanionRecord.self,
            OutboxEntry.self,
        ]
    }
}

public enum MeigichoMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
