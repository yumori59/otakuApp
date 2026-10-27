import Foundation
import Core
import Domain

/// `ProfileRepository` の HTTP 実装（`contract-mapping.md` §4.2）。
///
/// `GET /v1/me` / `PATCH /v1/me` はどちらも**認証必須**なので `.bearer`（既定）で送る。
/// access token が切れていれば `ApiClient` が refresh して 1 回だけ再送する。
public struct RemoteProfileRepository: ProfileRepository {
    private let client: ApiClient

    public init(client: ApiClient) {
        self.client = client
    }

    public func fetchMe() async throws -> MeSnapshot {
        try await client.send(.versioned(.get, "/me"), as: MeResponse.self).toDomain()
    }

    /// **読み取り専用キー（`account_id` / `plan` / `id`）は `UpdateMeRequest` に存在しない**ので送れない（C6）。
    public func updateMe(_ patch: ProfilePatch) async throws -> MeSnapshot {
        let body = try JSONEncoder().encode(UpdateMeRequest(patch: patch))
        return try await client.send(.versioned(.patch, "/me", body: body), as: MeResponse.self).toDomain()
    }

    /// `PUT /v1/me/avatar`（`api-contract-delta.md` §2）。
    /// JPEG バイナリを `multipart/form-data` で送り、更新後の `MeSnapshot` を返す。
    public func uploadAvatar(jpegData: Data) async throws -> MeSnapshot {
        let multipart = MultipartFormData.singleFile(
            name: "file",
            filename: "avatar.jpg",
            mimeType: "image/jpeg",
            data: jpegData
        )
        let endpoint = Endpoint.versioned(
            .put,
            "/me/avatar",
            body: multipart.body,
            contentType: multipart.contentType
        )
        return try await client.send(endpoint, as: MeResponse.self).toDomain()
    }

    /// `DELETE /v1/me/avatar`（§3）。冪等。削除後の `MeSnapshot`（`avatar_url: null`）を返す。
    public func deleteAvatar() async throws -> MeSnapshot {
        try await client.send(.versioned(.delete, "/me/avatar"), as: MeResponse.self).toDomain()
    }
}
