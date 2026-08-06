import Foundation
import Core
import Domain

/// `IdentityRepository` の HTTP 実装（`contract-mapping.md` §4.3）。
public struct RemoteIdentityRepository: IdentityRepository {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    public func list() async throws -> [Identity] {
        let response = try await client.send(
            .versioned(.get, "/identities", query: [URLQueryItem(name: "include_deleted", value: "false")]),
            as: IdentityListResponse.self
        )
        return response.items.map { $0.toDomain() }
    }

    public func create(_ identity: Identity) async throws -> Identity {
        let body = try JSONEncoder().encode(identity.toCreateRequest())
        let response = try await client.send(.versioned(.post, "/identities", body: body), as: IdentityResponse.self)
        return response.toDomain()
    }

    public func update(id: UUID, _ patch: IdentityPatch) async throws -> Identity {
        let body = try JSONEncoder().encode(patch.toRequest())
        let response = try await client.send(
            .versioned(.patch, "/identities/\(id.uuidString.lowercased())", body: body),
            as: IdentityResponse.self
        )
        return response.toDomain()
    }

    public func delete(id: UUID) async throws {
        try await client.sendVoid(.versioned(.delete, "/identities/\(id.uuidString.lowercased())"))
    }
}
