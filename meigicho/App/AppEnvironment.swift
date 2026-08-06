import Foundation
import Domain
import Network

/// Composition Root。`Info.plist` の `API_BASE_URL` を読み、クライアントと Repository を組み立てる。
///
/// - `Features` はこの型を知らない。**具象の注入はここだけ**（IOS-5）
/// - T0 の時点では `InMemory*Repository`（`SampleData`）を注入する。
///   ネットワーク実装（`Remote*Repository`）は T1 以降で差し替える
@MainActor
final class AppEnvironment {
    let configuration: ApiConfiguration
    /// 認証あり（`/v1/*`）。T1 が `TokenStore` と 401 refresh を足す
    let apiClient: ApiClient
    /// 認証なし（`/public/*`）。**共有ボード専用。Bearer を持たない**（contract-mapping §5.1）
    let publicApiClient: PublicApiClient

    /// Google サインイン（`GOOGLE_IOS_CLIENT_ID` 未設定なら nil）
    let googleSignIn: (any GoogleSignInProviding)?

    let authRepository: any AuthRepository
    let profileRepository: any ProfileRepository
    let identityRepository: any IdentityRepository
    let membershipRepository: any MembershipRepository
    let catalogRepository: any CatalogRepository
    let applicationRepository: any ApplicationRepository
    let shareRepository: any ShareRepository
    let sharedBoardRepository: any SharedBoardRepository
    let homeRepository: any HomeRepository
    let statsRepository: any StatsRepository
    /// 受け取った共有 token（Keychain・**自分の refresh token とは別 service 名前空間**）
    let sharedBoardTokenStore: any SharedBoardTokenStoring

    init(baseURL: URL, useInMemoryStores: Bool) {
        configuration = ApiConfiguration(baseURL: baseURL)
        // refresh token は Keychain。UI テスト時だけ Keychain に触らない
        let tokenStore: any RefreshTokenStoring = useInMemoryStores ? InMemoryTokenStore() : KeychainTokenStore()
        let apiClient = ApiClient(configuration: configuration, tokenStore: tokenStore)
        self.apiClient = apiClient
        publicApiClient = PublicApiClient(configuration: configuration)
        googleSignIn = useInMemoryStores ? nil : GoogleSignInService.makeFromBundle()

        // 認証・プロフィール・名義・会員情報・申込・ツアー/公演・共有リンク（オーナー側）は接続済み。
        authRepository = useInMemoryStores ? InMemoryAuthRepository() : RemoteAuthRepository(client: apiClient)
        profileRepository = useInMemoryStores ? InMemoryProfileRepository() : RemoteProfileRepository(client: apiClient)
        identityRepository = useInMemoryStores ? InMemoryIdentityRepository() : RemoteIdentityRepository(client: apiClient)
        membershipRepository = useInMemoryStores ? InMemoryMembershipRepository() : RemoteMembershipRepository(client: apiClient)
        catalogRepository = useInMemoryStores ? InMemoryCatalogRepository() : RemoteCatalogRepository(client: apiClient)
        applicationRepository = useInMemoryStores ? InMemoryApplicationRepository() : RemoteApplicationRepository(client: apiClient)
        shareRepository = useInMemoryStores ? InMemoryShareRepository() : RemoteShareRepository(client: apiClient)
        homeRepository = useInMemoryStores ? InMemoryHomeRepository() : RemoteHomeRepository(client: apiClient)
        statsRepository = useInMemoryStores ? InMemoryStatsRepository() : RemoteStatsRepository(client: apiClient)
        // 共有ボード（受け取り側）は **`publicApiClient` だけ**を使う。
        // `apiClient` を渡すと 401 refresh 経由で自分のアカウントがログアウトしうる（R7 / AC-SB-13-M）
        sharedBoardRepository = useInMemoryStores
            ? InMemorySharedBoardRepository()
            : RemoteSharedBoardRepository(client: publicApiClient)
        sharedBoardTokenStore = useInMemoryStores
            ? InMemorySharedBoardTokenStore()
            : KeychainSharedBoardTokenStore()
    }

    static func make() -> AppEnvironment {
        AppEnvironment(baseURL: resolvedBaseURL(), useInMemoryStores: shouldUseInMemoryStores())
    }

    /// `Info.plist` の `API_BASE_URL`（`$(API_BASE_URL)` でビルド構成から流し込む）。
    static func resolvedBaseURL() -> URL {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = URL(string: raw), url.scheme != nil {
            return url
        }
        // 構成が壊れていてもクラッシュさせない。ローカル開発の既定値に落とす
        return URL(string: "http://localhost:8080")!
    }

    static func shouldUseInMemoryStores() -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-UITestUseInMemoryStores")
        #else
        return false
        #endif
    }
}
