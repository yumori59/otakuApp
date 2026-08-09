import Foundation
import SwiftUI
import UIKit
import Core
import Domain
import Networking
import DataStore
import DesignSystem
import Features
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
    /// 編集後デバウンス（`docs/05` §5 のトリガ表: 3 秒）
    private static let editSyncDebounceSeconds: Double = 3

    let configuration: ApiConfiguration
    /// 認証あり（`/v1/*`）。T1 が `TokenStore` と 401 refresh を足す。
    /// **共有の受け取り側もこれを使う**（`/public/*` は廃止 — `api-contract-delta.md` §4.2）
    let apiClient: ApiClient

    /// Google サインイン（`GOOGLE_IOS_CLIENT_ID` 未設定なら nil）
    let googleSignIn: (any GoogleSignInProviding)?

    let authRepository: any AuthRepository
    let profileRepository: any ProfileRepository
    let identityRepository: any IdentityRepository
    let membershipRepository: any MembershipRepository
    let catalogRepository: any CatalogRepository
    let applicationRepository: any ApplicationRepository
    let shareRepository: any ShareRepository
    /// 共有ボード（受け取り側・`GET|PATCH /v1/shares/received/:id`）
    let sharedBoardRepository: any SharedBoardRepository
    /// 受信箱（`GET /v1/shares/received` / `redeem` / `hide`）
    let sharedInboxRepository: any SharedInboxRepository
    let homeRepository: any HomeRepository
    let statsRepository: any StatsRepository

    /// ローカル SSoT の入れ物。UI テスト（インメモリ Store）では作らない
    let modelContainer: ModelContainer?
    /// push→pull のサイクルを担う actor。UI テストでは nil（ネットワーク/ディスクに触らせない）
    let syncEngine: SyncEngine?
    let reachability: Reachability?
    /// 編集後 3 秒デバウンスの待機（ログアウト時に取り消す）。UI テストでは nil
    private let editSyncDebouncer: Debouncer?
    /// ホームの同期バナーが購読する状態（`Features` からは `Domain.SyncStatusStore` として見える）
    let syncStatusStore: SyncStatusStore

    // MARK: - 広告（admob-integration Stage 1）

    /// 表示可否（`AdGatekeeper`）とセッション状態。SDK には依存しない
    let adsStore: AdsStore
    /// SDK 実装。`ADMOB_APP_ID` が空なら `DisabledAdRenderer`（F1-6 / AC-AD-36）
    let adRenderer: any DesignSystem.AdRenderer
    /// `Features` に App 層の値（ユニット ID・到達性）を渡す橋（IOS-5）
    private(set) var adsBridge: AdsBridge = .noop
    /// バックグラウンドに入った時刻。復帰時のセッション判定に使う（Q10 / AC-AD-28）
    private var backgroundedAt: Date?

    init(baseURL: URL, useInMemoryStores: Bool) {
        configuration = ApiConfiguration(baseURL: baseURL)
        // refresh token は Keychain。UI テスト時だけ Keychain に触らない
        let tokenStore: any RefreshTokenStoring = useInMemoryStores ? InMemoryTokenStore() : KeychainTokenStore()
        let apiClient = ApiClient(configuration: configuration, tokenStore: tokenStore)
        self.apiClient = apiClient
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
            editSyncDebouncer = nil
        } else {
            // ローカル SSoT（SwiftData）+ バックグラウンド同期（`docs/05` §5 / ios-sync-engine T4）。
            // ディスク永続化に失敗しても起動は止めない（インメモリへフォールバック）
            let container = (try? ModelContainerFactory.makePersistent()) ?? Self.fallbackInMemoryContainer()
            modelContainer = container

            // Repository より先に engine を組む（Repository の書き込みフックが engine を捕まえるため）
            let reach = Reachability()
            reachability = reach
            let engine = SyncEngine(
                container: container,
                remote: RemoteSyncRepository(client: apiClient),
                reachability: reach,
                statusSink: .binding(statusStore),
                cursorDefaultsKey: Self.syncCursorDefaultsKey
            )
            syncEngine = engine

            // 編集後 3 秒デバウンス（`docs/05` §5 のトリガ表）。
            // Repository は `SyncEngine` を知らない（IOS-5）。ここで「書いた」通知を
            // デバウンス済みの `requestSync(reason: .edit)` に変換する。
            // 読み取り（`list` など）では発火しないので、起動直後の初期ロードでは走らない
            let debouncer = Debouncer(seconds: Self.editSyncDebounceSeconds)
            let onWrite = LocalWriteObserver {
                Task {
                    await debouncer.call {
                        // 未ログイン中の編集で毎回「同期できていません」を出さない。
                        // トークンがあれば（オフライン復帰待ちでも）通常どおり試す
                        guard await apiClient.currentRefreshToken() != nil else { return }
                        await engine.requestSync(reason: .edit)
                    }
                }
            }
            editSyncDebouncer = debouncer

            identityRepository = SwiftDataIdentityRepository(container: container, onWrite: onWrite)
            membershipRepository = SwiftDataMembershipRepository(container: container, onWrite: onWrite)
            catalogRepository = SwiftDataCatalogRepository(container: container, onWrite: onWrite)
            applicationRepository = SwiftDataApplicationRepository(container: container, onWrite: onWrite)
        }

        shareRepository = useInMemoryStores ? InMemoryShareRepository() : RemoteShareRepository(client: apiClient)
        homeRepository = useInMemoryStores ? InMemoryHomeRepository() : RemoteHomeRepository(client: apiClient)
        statsRepository = useInMemoryStores ? InMemoryStatsRepository() : RemoteStatsRepository(client: apiClient)
        // 共有の受け取り側は **招待されたアカウントだけ**が開ける経路になった（`api-contract-delta.md` §4.2）。
        // 公開経路（旧 `PublicApiClient` / `/public/shares/:token`）は廃止済みで、
        // ボードも受信箱も自分の `apiClient`（Bearer + 401 refresh）で叩く
        sharedBoardRepository = useInMemoryStores
            ? InMemorySharedBoardRepository()
            : RemoteSharedBoardRepository(client: apiClient)
        sharedInboxRepository = useInMemoryStores
            ? InMemorySharedInboxRepository()
            : RemoteSharedInboxRepository(client: apiClient)

        // 広告。UI テストでは SDK にもネットワークにも触らせない（`DisabledAdRenderer` + ユニット ID 空）。
        // `AdsInitializer.start()` は `GoogleMobileAdsRenderer.init` が呼ぶ（`App/Ads/GoogleMobileAdsRenderer.swift:20`）
        adsStore = AdsStore()
        let adUnitIDs = useInMemoryStores ? [:] : Self.resolvedAdUnitIDs()
        // ユニット ID が 1 つも無いなら SDK を初期化しない（F1-6 / N6 / AC-AD-36）。
        // `ADMOB_APP_ID` は plist 検証のため常に非空だが、それだけでは配信を始めない
        adRenderer = useInMemoryStores
            ? DisabledAdRenderer()
            : AdRendererFactory.make(hasConfiguredUnitIDs: !adUnitIDs.isEmpty)
        let adsStore = self.adsStore
        let reachability = self.reachability
        adsBridge = AdsBridge(
            unitIDs: adUnitIDs,
            refreshOnline: {
                guard let reachability else { return }
                await reachability.refresh()
                let isOnline = await reachability.isOnline
                await MainActor.run { adsStore.setOnline(isOnline) }
            }
        )
        observeAdsLifecycle()
    }

    /// `Info.plist` の `ADMOB_UNIT_*`（`project.yml` の設定から流し込む）。
    /// 未設定（空文字）の面は辞書に入れず、`AdSlot` 側で高さ 0 になるようにする（E1 / AC-AD-36）。
    /// リワード広告のユニット ID は Stage 2 の別タスクで追加する。
    private static func resolvedAdUnitIDs() -> [AdPlacement: String] {
        let keys: [AdPlacement: String] = [
            .identitiesBottom: "ADMOB_UNIT_IDENTITIES_BANNER",
            .tourTableBetween: "ADMOB_UNIT_TOURTABLE_BANNER",
            .identityDetailBottom: "ADMOB_UNIT_IDENTITYDETAIL_BANNER",
            .homeBottom: "ADMOB_UNIT_HOME_NATIVE",
            .applicationsInline: "ADMOB_UNIT_APPLICATIONS_NATIVE"
        ]
        return keys.compactMapValues { key in
            let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }

    /// 前面復帰で広告セッションを判定し直す（Q10 / AC-AD-28）。
    ///
    /// `MeigichoApp.swift` の `scenePhase` 監視は「ログイン済みのときだけ同期する」条件付きで、
    /// 広告セッションはログイン状態と無関係なので**ここで完結**させる。
    private func observeAdsLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundedAt = Date() }
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 記録が無い（初回起動直後など）ときは「十分長く落ちていた」と見なしてリセット側に倒す
                let duration = self.backgroundedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
                self.backgroundedAt = nil
                self.adsStore.handleForegroundReturn(backgroundDuration: duration)
            }
        }
    }

    /// `AuthState.signedOut` を受けたときの後始末。
    ///
    /// **`.signedOut` はログアウトとは限らない**。オフラインで起動して refresh に失敗しただけの場合
    /// (`SessionRestoreResult.unavailable`) も `.signedOut` になるが、そのとき Keychain の refresh token は
    /// 残っている。ここでローカルを消すと**未送信の編集が失われる**（AC-SY-04 違反）ので、
    /// トークンが実際に消えている（= 明示ログアウト / アカウント削除 / サイレントログアウト）ときだけ消す。
    func resetLocalStoreIfSessionCleared() async {
        guard await apiClient.currentRefreshToken() == nil else { return }
        await resetLocalStore()
    }

    /// ログアウト/アカウント削除時に前ユーザーのローカルデータと同期カーソルを消す。
    /// `ownerID` を使ったユーザースコープ絞り込みは未実装のため、
    /// クリアしないと他アカウントのデータが混入する（T3 申し送り事項1）。
    func resetLocalStore() async {
        // 消す直前まで打鍵していた場合、待機中の `.edit` 同期が消去後に走ると
        // 空のローカルを push しかねない。先に取り消す
        await editSyncDebouncer?.cancel()
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

extension View {
    /// 広告の Composition Root 配線（admob-integration T10）。
    /// `Features` は `AdsStore` / `AdRenderer` / `AdsBridge` を `@Environment` 経由でしか見ない（IOS-5）。
    func adsEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment.adsStore)
            .environment(\.adRenderer, environment.adRenderer)
            .environment(\.adsBridge, environment.adsBridge)
    }
}
