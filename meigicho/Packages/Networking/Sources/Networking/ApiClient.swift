import Foundation
import Core
import Domain

/// 認証あり（Bearer）の API クライアント。`/v1/*` 専用。
///
/// - `accessToken` の保持と差し替えを内部に閉じる（actor）
/// - refresh token は `RefreshTokenStoring`（既定は Keychain）に置く
/// - **401 を受けたら refresh → 1 回だけ再送**。並行 401 でも refresh は 1 回だけ走る（E-5 / FR-N-6）
/// - **`/v1/*` 専用**。旧公開経路（`/public/shares/:token` 系）は `api-contract-delta.md` Q1=A で廃止された。
///   受け取り側の共有ボードも含め、全ての経路が Bearer 必須になったため `PublicApiClient` は存在しない
///   （`api-contract-delta.md` §6.1）
public actor ApiClient {
    /// リクエストに Bearer を付けるか。
    /// `/v1/auth/*`（apple / google / refresh / logout / register / login / password/reset*）は
    /// **Public なので `.none`**。`.none` は 401 でも refresh を試みない（サインイン失敗で
    /// 自分のセッションを巻き込まないため）。
    public enum Authorization: Sendable, Equatable {
        case bearer
        case none
    }

    private let configuration: ApiConfiguration
    private let session: URLSession
    private let tokenStore: any RefreshTokenStoring
    private let logger = AppLogger(category: "auth")

    private var accessToken: String?
    private var accessTokenExpiresAt: Date?
    /// 実行中の refresh。**並行 401 をここに集約する**（refresh は回転式なので同時実行すると片方が必ず失効する）
    private var refreshTask: Task<String, Error>?
    /// セッションの世代。ログアウト / 別セッション採用のたびに進める。
    /// **進行中の refresh が完了しても、古い世代の結果は Keychain に書かない**
    /// （ログアウトしたユーザーが次回起動で黙って復帰する事故を防ぐ）
    private var sessionEpoch = 0
    /// AC-AUTH-08-M の確認用（ログにだけ出す。値は出さない）
    private var refreshCount = 0
    private var sessionEndedHandler: (@Sendable () async -> Void)?

    public init(
        configuration: ApiConfiguration,
        tokenStore: any RefreshTokenStoring = KeychainTokenStore(),
        session: URLSession? = nil
    ) {
        self.configuration = configuration
        self.session = session ?? configuration.makeSession()
        self.tokenStore = tokenStore
    }

    // MARK: - 送信

    public func send<T: Decodable & Sendable>(
        _ endpoint: Endpoint,
        as type: T.Type,
        authorization: Authorization = .bearer
    ) async throws -> T {
        let data = try await perform(endpoint, authorization: authorization, promoteError: nil)
        return try ResponseValidator.decode(type, from: data)
    }

    /// エラー envelope を**呼び出し側の文脈で読み替えたい**ときの変種。
    ///
    /// `promoteError` が `nil` を返せば通常の `AppError.from(envelope:)` のままになる。
    /// **`details` の形をこのクライアントに知らせないため**のフック。
    /// 利用者は `RemoteShareRepository`（`SHARE_RECIPIENT_UNKNOWN` → `details.unknown_account_ids`）と
    /// `RemoteSharedBoardRepository`（`CONFLICT` → `.shareItemConflict(current:)`）。
    public func send<T: Decodable & Sendable>(
        _ endpoint: Endpoint,
        as type: T.Type,
        authorization: Authorization = .bearer,
        promoteError: @escaping @Sendable (APIErrorEnvelope) -> AppError?
    ) async throws -> T {
        let data = try await perform(endpoint, authorization: authorization, promoteError: promoteError)
        return try ResponseValidator.decode(type, from: data)
    }

    /// 204 など本文が無い経路。
    public func sendVoid(_ endpoint: Endpoint, authorization: Authorization = .bearer) async throws {
        _ = try await perform(endpoint, authorization: authorization, promoteError: nil)
    }

    private func perform(
        _ endpoint: Endpoint,
        authorization: Authorization,
        promoteError: (@Sendable (APIErrorEnvelope) -> AppError?)?
    ) async throws -> Data {
        guard endpoint.path.isVersioned else {
            // `/health` 系以外の非バージョン経路は存在しない（旧 `/public/*` は廃止済み）
            throw AppError.decoding("ApiClient received a non-versioned endpoint.")
        }

        guard authorization == .bearer else {
            return try await rawSend(endpoint, bearer: nil, promoteError: promoteError)
        }

        // 起動直後は access token がメモリに無い（Keychain の refresh token から取り直す）
        var token = accessToken
        if token == nil {
            token = try await currentAccessToken(replacing: nil)
        }

        do {
            return try await rawSend(endpoint, bearer: token, promoteError: promoteError)
        } catch AppError.unauthenticated {
            // 401 は 1 回だけ refresh して再送する。**再送後の 401 はそのままエラー**（無限ループ防止）
            let refreshed = try await currentAccessToken(replacing: token)
            return try await rawSend(endpoint, bearer: refreshed, promoteError: promoteError)
        }
    }

    /// リトライを含まない素の送信。
    private func rawSend(
        _ endpoint: Endpoint,
        bearer: String?,
        promoteError: (@Sendable (APIErrorEnvelope) -> AppError?)?
    ) async throws -> Data {
        var headers: [String: String] = [:]
        if let bearer {
            headers["Authorization"] = "Bearer \(bearer)"
        }
        let request = try endpoint.urlRequest(baseURL: configuration.baseURL, extraHeaders: headers)
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

    // MARK: - refresh の直列化

    /// 有効な access token を返す。
    /// `replacing` には「失敗したリクエストが使ったトークン」を渡す。
    /// 既に別の refresh が完了して別のトークンになっていれば、**refresh せずにそれを使う**（E-5）。
    private func currentAccessToken(replacing previous: String?) async throws -> String {
        if let current = accessToken, current != previous {
            return current
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let epoch = sessionEpoch
        let task = Task<String, Error> { [self] in
            try await runRefresh(epoch: epoch)
        }
        refreshTask = task
        do {
            let token = try await task.value
            // 世代が変わっていれば新しい refresh が始まっているかもしれない。その task を消さない
            if epoch == sessionEpoch { refreshTask = nil }
            return token
        } catch {
            if epoch == sessionEpoch { refreshTask = nil }
            throw error
        }
    }

    /// ログアウト / 別セッションの採用。**進行中の refresh の結果を捨てる**。
    private func beginNewSessionEpoch() {
        sessionEpoch &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func runRefresh(epoch: Int) async throws -> String {
        guard let refreshToken = await tokenStore.read() else {
            await endSession()
            throw AppError.sessionExpired
        }

        refreshCount += 1
        logger.event("auth_refresh_\(refreshCount)")

        do {
            let body = try JSONEncoder().encode(RefreshRequest(refreshToken: refreshToken))
            let data = try await rawSend(.versioned(.post, "/auth/refresh", body: body), bearer: nil, promoteError: nil)
            let pair = try ResponseValidator.decode(TokenPairResponse.self, from: data).toDomain(receivedAt: Date())
            guard epoch == sessionEpoch else {
                // refresh 中にログアウト / 別セッション採用が起きた。**この結果は採用しない**
                logger.event("auth_refresh_discarded_stale_session")
                throw AppError.sessionExpired
            }
            guard await store(pair, epoch: epoch) else {
                // `store` 内の `await tokenStore.write` が中断している間にログアウト / 別セッション採用が
                // 割り込んだ（中-2 残余）。書き込みは打ち消し済みなのでこの結果は採用しない
                logger.event("auth_refresh_discarded_stale_session")
                throw AppError.sessionExpired
            }
            return pair.accessToken
        } catch let error as AppError {
            // `AUTH_REFRESH_INVALID` / `UNAUTHENTICATED` は復帰不能。**サイレントログアウト**（E-6 / AC-AUTH-09-M）
            // ただし世代が変わっていれば、この失敗は**既に終わったセッションの話**。
            // 新しいセッションを巻き込んで消さない
            if error.isSessionEnding, epoch == sessionEpoch {
                await endSession()
            }
            throw error
        }
    }

    /// トークンを採用する。`epoch` は呼び出し時点のセッション世代。
    ///
    /// `await tokenStore.write` はそれ自体が中断点であり、この最中に `clearSession` /
    /// `adoptSession` が割り込んで世代を進める余地がある（中-2 残余。`sessionEpoch` の一致だけを
    /// `store` 呼び出し前に見ても閉じない窓）。書き込み**後**にもう一度世代を確認し、
    /// ズレていれば直前の書き込みを打ち消して Keychain を空に戻す。
    /// 戻り値は「採用できたか」。呼び出し側は `false` ならこのトークンを使わない。
    @discardableResult
    private func store(_ tokens: TokenPair, epoch: Int) async -> Bool {
        accessToken = tokens.accessToken
        accessTokenExpiresAt = tokens.expiresAt
        await tokenStore.write(tokens.refreshToken)
        guard epoch == sessionEpoch else {
            accessToken = nil
            accessTokenExpiresAt = nil
            await tokenStore.clear()
            return false
        }
        return true
    }

    private func endSession() async {
        beginNewSessionEpoch()
        accessToken = nil
        accessTokenExpiresAt = nil
        await tokenStore.clear()
        await sessionEndedHandler?()
    }
}

// MARK: - AuthSessionController

/// `AuthStore`（Domain）から見たセッション操作の実体。
/// Domain は `Network` を知らないため、protocol 越しに注入する（IOS-5）。
extension ApiClient: AuthSessionController {
    public func adoptSession(_ tokens: TokenPair) async {
        // 進行中の refresh（前のセッションのもの）に上書きされないよう世代を進める
        beginNewSessionEpoch()
        await store(tokens, epoch: sessionEpoch)
    }

    public func clearSession() async {
        // 進行中の refresh が完了しても Keychain に書き戻させない（ログアウトの取り消し防止）
        beginNewSessionEpoch()
        accessToken = nil
        accessTokenExpiresAt = nil
        await tokenStore.clear()
    }

    public func currentRefreshToken() async -> String? {
        await tokenStore.read()
    }

    public func setSessionEndedHandler(_ handler: @escaping @Sendable () async -> Void) async {
        sessionEndedHandler = handler
    }

    /// 起動時の復帰。Keychain に refresh token があれば 1 回だけ refresh する。
    ///
    /// - `.signedOut`: token が無い / 失効している（Keychain はクリア済み）
    /// - `.unavailable`: 通信できないだけ。**token は消さない**（オフライン起動でログアウトさせない）
    public func restoreSession() async -> SessionRestoreResult {
        guard await tokenStore.read() != nil else { return .signedOut }
        if let expiresAt = accessTokenExpiresAt, accessToken != nil, expiresAt > Date() {
            return .restored
        }
        do {
            _ = try await currentAccessToken(replacing: accessToken)
            return .restored
        } catch let error as AppError {
            return error.isSessionEnding ? .signedOut : .unavailable(error)
        } catch {
            return .unavailable(.unknown(code: "TRANSPORT", message: nil))
        }
    }
}
