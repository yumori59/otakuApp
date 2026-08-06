import Foundation
import SwiftData

/// Schema V1 — identities のみ（`docs/plans/ios-sync-engine` T1）。
public enum SchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [IdentityRecord.self, OutboxEntry.self]
    }
}

public enum MeigichoMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [SchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}
