import Foundation
import Core
import Domain

/// `CatalogRepository`（tours + events）の HTTP 実装（`contract-mapping.md` §4.5）。
///
/// **作成メソッドを持たない。** `POST /v1/tours` / `POST /v1/events` は存在せず、
/// tour / event は `POST /v1/applications` の find-or-create でしか作れない（C3）。
public struct RemoteCatalogRepository: CatalogRepository {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    public func listTours() async throws -> [Tour] {
        let response = try await client.send(.versioned(.get, "/tours"), as: TourListResponse.self)
        return try response.items.map { try $0.toDomain() }
    }

    public func listEvents() async throws -> [EventEntity] {
        let response = try await client.send(.versioned(.get, "/events"), as: EventListResponse.self)
        return try response.items.map { try $0.toDomain() }
    }

    /// 手元に無い公演を 1 件だけ埋めるための単発取得（`contract-mapping.md` §4.6）。
    public func fetchEvent(id: UUID) async throws -> EventEntity {
        let response = try await client.send(
            .versioned(.get, "/events/\(id.uuidString.lowercased())"),
            as: EventResponse.self
        )
        return try response.toDomain()
    }

    public func updateTour(id: UUID, _ patch: TourPatch) async throws -> Tour {
        let body = try JSONEncoder().encode(UpdateTourRequest(patch: patch))
        let response = try await client.send(
            .versioned(.patch, "/tours/\(id.uuidString.lowercased())", body: body),
            as: TourResponse.self
        )
        return try response.toDomain()
    }

    public func updateEvent(id: UUID, _ patch: EventPatch) async throws -> EventEntity {
        let body = try JSONEncoder().encode(UpdateEventRequest(patch: patch))
        let response = try await client.send(
            .versioned(.patch, "/events/\(id.uuidString.lowercased())", body: body),
            as: EventResponse.self
        )
        return try response.toDomain()
    }
}
