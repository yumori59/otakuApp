import Foundation
import Core
import Domain

/// **認証なし**の API クライアント。`/public/*` 専用（`contract-mapping.md` §5.1）。
///
/// このファイルには意図的に次のものが**存在しない**:
/// - `Authorization` ヘッダの組み立て
/// - `TokenStore` / `ApiClient` への参照
/// - 401 を受けたときの refresh / ログアウト
///
/// 理由: 共有リンクを受け取った人は自分のアカウントでログインしていない前提であり、
/// 公開経路の 401 で**自分のアカウントをログアウトさせてはならない**（R7 / AC-SB-13-M）。
/// また `/v1` プレフィックスも付けない（`GLOBAL_PREFIX_EXCLUDE`）。
public actor PublicApiClient {
    private let configuration: ApiConfiguration
    private let session: URLSession

    public init(configuration: ApiConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? configuration.makeSession()
    }

    public func send<T: Decodable & Sendable>(_ endpoint: Endpoint, as type: T.Type) async throws -> T {
        let data = try await perform(endpoint, promoteError: nil)
        return try ResponseValidator.decode(type, from: data)
    }

    /// エラー envelope を**呼び出し側の文脈で読み替えたい**ときの変種（T4b）。
    ///
    /// `promoteError` が `nil` を返せば通常の `AppError.from(envelope:)` のままになる。
    /// **`details` の形をこのクライアントに知らせないため**のフック。
    /// 現在の唯一の利用者は `RemoteSharedBoardRepository`（`CONFLICT` → `.shareItemConflict(current:)`）。
    ///
    /// 認証を持たない・リトライしないという `send` の性質はそのまま。
    public func send<T: Decodable & Sendable>(
        _ endpoint: Endpoint,
        as type: T.Type,
        promoteError: @Sendable @escaping (APIErrorEnvelope) -> AppError?
    ) async throws -> T {
        let data = try await perform(endpoint, promoteError: promoteError)
        return try ResponseValidator.decode(type, from: data)
    }

    public func sendVoid(_ endpoint: Endpoint) async throws {
        _ = try await perform(endpoint, promoteError: nil)
    }

    private func perform(
        _ endpoint: Endpoint,
        promoteError: (@Sendable (APIErrorEnvelope) -> AppError?)?
    ) async throws -> Data {
        guard !endpoint.path.isVersioned else {
            throw AppError.decoding("PublicApiClient received a versioned endpoint. Use ApiClient.")
        }

        // ヘッダは Endpoint が組み立てるものだけ。**追加のヘッダを渡さない**
        let request = try endpoint.urlRequest(baseURL: configuration.baseURL, extraHeaders: [:])

        // リトライを一切しない（401 でも再送しない）
        do {
            let (data, response) = try await session.data(for: request)
            do {
                try ResponseValidator.validate(data: data, response: response)
            } catch let error as AppError {
                // 2xx 以外。呼び出し側が envelope を読み替えたい場合だけ差し替える
                guard let promoteError,
                      let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data),
                      let promoted = promoteError(envelope)
                else { throw error }
                throw promoted
            }
            return data
        } catch {
            throw ResponseValidator.mapTransportError(error)
        }
    }
}
