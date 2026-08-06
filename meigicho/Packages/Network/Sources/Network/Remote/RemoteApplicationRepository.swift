import Foundation
import Core
import Domain

/// `ApplicationRepository` の HTTP 実装（`contract-mapping.md` §4.6）。
///
/// - `cursor` は **opaque**。`next_cursor` をそのまま次リクエストへ渡すだけで、中身を解釈しない（C7）
/// - ページ反復（何ページで打ち切るか）は `ApplicationStore` の責務。ここは 1 ページだけを扱う
/// - `rep_membership_id` は `CreateApplicationRequest` が常に null を書く（FR-AP-7）
public struct RemoteApplicationRepository: ApplicationRepository {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    public func listPage(limit: Int, cursor: String?) async throws -> ApplicationPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty {
            query.append(URLQueryItem(name: "cursor", value: cursor))
        }
        let response = try await client.send(
            .versioned(.get, "/applications", query: query),
            as: ApplicationPageResponse.self
        )
        return try response.toDomain()
    }

    public func create(_ draft: ApplicationDraft) async throws -> ApplicationEntry {
        let body = try JSONEncoder().encode(CreateApplicationRequest(draft: draft))
        let response = try await client.send(
            .versioned(.post, "/applications", body: body),
            as: ApplicationResponse.self
        )
        return try response.toDomain()
    }

    public func update(id: UUID, _ patch: ApplicationPatch) async throws -> ApplicationEntry {
        let body = try JSONEncoder().encode(UpdateApplicationRequest(patch: patch))
        let response = try await client.send(
            .versioned(.patch, "/applications/\(id.uuidString.lowercased())", body: body),
            as: ApplicationResponse.self
        )
        return try response.toDomain()
    }

    public func delete(id: UUID) async throws {
        try await client.sendVoid(
            .versioned(.delete, "/applications/\(id.uuidString.lowercased())")
        )
    }
}
