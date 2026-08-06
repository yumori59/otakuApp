import Foundation
import Domain
import Network
import DataStore
import SwiftData

/// Composition Root。`Info.plist` の `API_BASE_URL` を読み、クライアントと Repository を組み立てる。
///
/// - `Features` はこの型を知らない。**具象の注入はここだけ**（IOS-5）
/// - ios-sync-engine T4: identities/memberships/tours・events/applications はローカル SSoT
///   （SwiftData 経由の `SwiftData*Repository`）を正とし、`SyncEngine` がバックグラウンドで
///   `RemoteSyncRepository` と同期する。UI テスト（`useInMemoryStores`）はディスク/ネットワークに
///   触らない `InMemory*Repository` のままにする
@MainActor
final class AppEnvironment {
    /// `SyncEngine` の pull カーソル（T3 が導入した既定値をそのまま踏襲する）
    private static let syncCursorDefaultsKey = "meigicho.sync.cursor.v1"

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

    /// ローカル SSoT の入れ物。UI テスト（インメモリ Store）では作らない
    let modelContainer: ModelContainer?
    /// push→pull のサイクルを担う actor。UI テストでは nil（ネットワーク/ディスクに触らせない）
    let syncEngine: SyncEngine?
    let reachability: Reachability?
    /// ホームの同期バナーが購読する状態（`Features` からは `Domain.SyncStatusStore` として見える）
    let syncStatusStore: SyncStatusStore

    init(baseURL: URL, useInMemoryStores: Bool) {
        configuration = ApiConfiguration(baseURL: baseURL)
        // refresh token は Keychain。UI テスト時だけ Keychain に触らない
        let tokenStore: any RefreshTokenStoring = useInMemoryStores ? InMemoryTokenStore() : KeychainTokenStore()
        let apiClient = ApiClient(configuration: configuration, tokenStore: tokenStore)
        self.apiClient = apiClient
        publicApiClient = PublicApiClient(configuration: configuration)
        googleSignIn = useInMemoryStores ? nil : GoogleSignInService.makeFromBundle()

        // 認証・プロフィール・共有リンク（オーナー側）はサーバー直結のまま（同期対象外コレクション）
        authRepository = useInMemoryStores ? InMemoryAuthRepository() : RemoteAuthRepository(client: apiClient)
        profileRepository = useInMemoryStores ? InMemoryProfileRepository() : RemoteProfileRepository(client: apiClient)

        let statusStore = SyncStatusStore()
        syncStatusStore = statusStore

        if useInMemoryStores {
            identityRepository = InMemoryIdentityRepository()
            membershipRepository = InMemoryMembershipRepository()
            catalogRepository = InMemoryCatalogRepository()
            applicationRepository = InMemoryApplicationRepository()
            modelContainer = nil
            syncEngine = nil
            reachability = nil
        } else {
            // ローカル SSoT（SwiftData）+ バックグラウンド同期（`docs/05` §5 / ios-sync-engine T4）。
            // ディスク永続化に失敗しても起動は止めない（インメモリへフォールバック）
            let container = (try? ModelContainerFactory.makePersistent()) ?? Self.fallbackInMemoryContainer()
            modelContainer = container
            identityRepository = SwiftDataIdentityRepository(container: container)
            membershipRepository = SwiftDataMembershipRepository(container: container)
            catalogRepository = SwiftDataCatalogRepository(container: container)
            applicationRepository = SwiftDataApplicationRepository(container: container)

            let reach = Reachability()
            reachability = reach
            syncEngine = SyncEngine(
                container: container,
                remote: RemoteSyncRepository(client: apiClient),
                reachability: reach,
                statusSink: .binding(statusStore),
                cursorDefaultsKey: Self.syncCursorDefaultsKey
            )
        }

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

    /// ログアウト/アカウント削除時に前ユーザーのローカルデータと同期カーソルを消す。
    /// `ownerID` を使ったユーザースコープ絞り込みは未実装のため、
    /// クリアしないと他アカウントのデータが混入する（T3 申し送り事項1）。
    func resetLocalStore() async {
        UserDefaults.standard.removeObject(forKey: Self.syncCursorDefaultsKey)
        syncStatusStore.apply(.idle)
        syncStatusStore.setPendingCount(0)
        guard let modelContainer else { return }
        let context = ModelContext(modelContainer)
        do {
            try context.delete(model: ApplicationCompanionRecord.self)
            try context.delete(model: ApplicationRecord.self)
            try context.delete(model: EventRecord.self)
            try context.delete(model: TourRecord.self)
            try context.delete(model: MembershipRecord.self)
            try context.delete(model: IdentityRecord.self)
            try context.delete(model: OutboxEntry.self)
            try context.save()
        } catch {
            // 消し切れなくても次回ログインの pull で上書きされる（LWW）。ここでは握りつぶして続行する
        }
    }

    /// ディスク永続化に失敗した場合の最終フォールバック。インメモリの構築自体が失敗する状況は
    /// 開発機の設定ミス以外で起きないため、ここは `try!` で構わない。
    private static func fallbackInMemoryContainer() -> ModelContainer {
        // swiftlint:disable:next force_try
        try! ModelContainerFactory.makeInMemory()
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
