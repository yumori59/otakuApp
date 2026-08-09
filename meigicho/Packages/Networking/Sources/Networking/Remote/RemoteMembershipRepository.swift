import Foundation
import Core
import Domain

/// `MembershipRepository` の HTTP 実装（`contract-mapping.md` §4.4）。
public struct RemoteMembershipRepository: MembershipRepository {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    /// `identity_id` を指定しないので自分の全件が返る（§4.4）。
    public func list() async throws -> [Membership] {
        let response = try await client.send(.versioned(.get, "/memberships"), as: MembershipListResponse.self)
        return response.items.map { $0.toDomain() }
    }

    public func create(_ membership: Membership) async throws -> Membership {
        let body = try JSONEncoder().encode(membership.toCreateRequest())
        let response = try await client.send(.versioned(.post, "/memberships", body: body), as: MembershipResponse.self)
        return response.toDomain()
    }

    public func update(id: UUID, _ patch: MembershipPatch) async throws -> Membership {
        let body = try JSONEncoder().encode(patch.toRequest())
        let response = try await client.send(
            .versioned(.patch, "/memberships/\(id.uuidString.lowercased())", body: body),
            as: MembershipResponse.self
        )
        return response.toDomain()
    }

    public func delete(id: UUID) async throws {
        try await client.sendVoid(.versioned(.delete, "/memberships/\(id.uuidString.lowercased())"))
    }
}
