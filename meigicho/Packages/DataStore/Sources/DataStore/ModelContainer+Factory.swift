import Foundation
import SwiftData

public enum ModelContainerFactory {
    /// 本番／通常起動用（ディスク永続）。
    public static func makePersistent(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: MeigichoMigrationPlan.self,
            configurations: [configuration]
        )
    }

    /// テスト専用のインメモリコンテナ。
    public static func makeInMemory() throws -> ModelContainer {
        try makePersistent(inMemory: true)
    }
}
