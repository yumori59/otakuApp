import SwiftUI
import Features
import DesignSystem
import Domain
import UserNotifications
import UIKit

@main
struct MeigichoApp: App {
    @State private var environment: AppEnvironment
    @State private var themeStore = ThemeStore()
    @State private var identityStore: IdentityStore
    @State private var applicationStore: ApplicationStore
    @State private var appSettingsStore = AppSettingsStore()
    @State private var authStore: AuthStore
    @State private var profileStore: ProfileStore
    @State private var sheetPresenter = SheetPresenter()
    @State private var shareLinkStore: ShareLinkStore
    @State private var homeStore: HomeStore
    @State private var statsStore: StatsStore
    @State private var purchasesStore: PurchasesStore
    @State private var deepLinkCoordinator = DeepLinkCoordinator()
    @State private var notificationPermission = NotificationPermissionStore()

    private let notificationScheduler = NotificationScheduler()
    @State private var notificationDelegateInstalled = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let environment = AppEnvironment.make()
        _environment = State(initialValue: environment)
        _identityStore = State(initialValue: IdentityStore(
            repository: environment.identityRepository,
            membershipRepository: environment.membershipRepository
        ))
        _applicationStore = State(initialValue: ApplicationStore(
            repository: environment.applicationRepository,
            catalogRepository: environment.catalogRepository
        ))
        _authStore = State(initialValue: AuthStore(
            repository: environment.authRepository,
            session: environment.apiClient,
            googleSignIn: environment.googleSignIn
        ))
        _profileStore = State(initialValue: ProfileStore(repository: environment.profileRepository))
        _shareLinkStore = State(initialValue: ShareLinkStore(repository: environment.shareRepository))
        _homeStore = State(initialValue: HomeStore(repository: environment.homeRepository))
        _statsStore = State(initialValue: StatsStore(repository: environment.statsRepository))
        _purchasesStore = State(initialValue: PurchasesStore(service: PurchasesServiceFactory.make()))
    }

    var body: some Scene {
        WindowGroup {
            // ソフトゲート（Q5）。Keychain 復帰待ちだけスプラッシュ、
            // 未ログイン（ゲスト）でもタブは描く
            AuthGateView { MainTabView() }
                .environment(identityStore)
                .environment(applicationStore)
                .environment(appSettingsStore)
                .environment(authStore)
                .environment(profileStore)
                .environment(shareLinkStore)
                .environment(homeStore)
                .environment(statsStore)
                .environment(purchasesStore)
                .environment(sheetPresenter)
                .environment(deepLinkCoordinator)
                .environment(environment.syncStatusStore)
                // 広告（AdsStore / AdRenderer / AdsBridge）の注入は `AppEnvironment.adsEnvironment` が単独所有する
                .adsEnvironment(environment)
                .environment(\.themeStore, themeStore)
                .environment(\.notificationBridge, notificationBridge)
                .environment(\.syncActionBridge, syncActionBridge)
                // `meigicho://share/<token>` の受け口 + 受信箱 / 共有ボード用ストアの注入。
                // 未ログインで受けた token はサインイン後に再試行するため `authStore.state` を渡す（FR-4-3）
                .sharedBoardDeepLink(
                    environment: environment,
                    authState: authStore.state,
                    sheetPresenter: sheetPresenter
                )
                .onOpenURL { url in
                    _ = deepLinkCoordinator.handle(url: url)
                }
                .task {
                    guard !notificationDelegateInstalled else { return }
                    let coordinator = deepLinkCoordinator
                    UNUserNotificationCenter.current().delegate = NotificationDelegate { url in
                        await MainActor.run {
                            _ = coordinator.handle(url: url)
                        }
                    }
                    notificationDelegateInstalled = true
                    await notificationPermission.refresh()
                }
                .task {
                    // Keychain の refresh token でセッションを復帰する
                    await authStore.bootstrap()
                }
                .task(id: authStore.state) {
                    // ログイン後にだけ読み込む（Q5）
                    guard authStore.state == .signedIn else {
                        // ログアウト後もタブは見えたままなので、前のユーザーのデータを残さない
                        if authStore.state == .signedOut {
                            identityStore.clear()
                            applicationStore.clear()
                            homeStore.clear()
                            statsStore.clear()
                            purchasesStore.resetSession()
                            // 共有リンクは他人に渡す URL に直結するので、前のユーザーの分を残さない
                            shareLinkStore.clear()
                        }
                        return
                    }
                    async let apps: Void = applicationStore.load()
                    async let ids: Void = identityStore.load()
                    async let home: Void = homeStore.load()
                    async let stats: Void = statsStore.load()
                    _ = await (apps, ids, home, stats)
                    await rescheduleNotificationsIfAuthorized()
                }
                .task(id: authStore.state) {
                    // T1b: `GET /v1/me`。テーマ色とアプリ名は**サーバーの値が正**（AC-ME-01 / AC-ME-02）
                    guard authStore.state == .signedIn else {
                        if authStore.state == .signedOut {
                            profileStore.clear()
                            appSettingsStore.appDisplayName = nil
                        }
                        return
                    }
                    await profileStore.load()
                    guard let profile = profileStore.profile else { return }
                    themeStore.apply(hex: profile.themeColor)
                    appSettingsStore.appDisplayName = profile.appDisplayName
                    await purchasesStore.configureIfNeeded(userID: profile.userID)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                    Task {
                        await notificationPermission.refresh()
                        await rescheduleNotificationsIfAuthorized()
                    }
                }
                .task(id: authStore.state) {
                    // ローカルファースト同期（ios-sync-engine T4）。
                    // ログイン後に起動同期を1回走らせ、ログアウトでは前ユーザーのローカルデータ+
                    // カーソルを消す（他アカウント混入防止・T3 申し送り事項1）。
                    // **オフライン起動の `.signedOut` では消さない**（`resetLocalStoreIfSessionCleared`）
                    guard authStore.state == .signedIn else {
                        if authStore.state == .signedOut {
                            await environment.resetLocalStoreIfSessionCleared()
                        }
                        return
                    }
                    await environment.reachability?.start()
                    await syncAndRefresh(reason: .launch)
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active, authStore.state == .signedIn else { return }
                    Task {
                        await environment.reachability?.refresh()
                        await syncAndRefresh(reason: .foreground)
                    }
                }
        }
    }

    /// `Features/Home` の同期バナーが手動再試行で呼ぶ橋（`SyncEngine` は `Features` から直接見えない — AC-SY-05）
    private var syncActionBridge: SyncActionBridge {
        SyncActionBridge {
            await syncAndRefresh(reason: .manual)
        }
    }

    /// 同期サイクルを 1 回（多重起動は畳む）走らせ、**終わってからローカル SSoT を読む Store を読み直す**。
    /// pull した内容は SwiftData に入るだけで Store は自動更新されないため、ここで縦串を閉じる（IOS-3）。
    @MainActor
    private func syncAndRefresh(reason: SyncTrigger) async {
        guard let engine = environment.syncEngine else { return }
        await engine.syncNow(reason: reason)
        async let identities: Void = identityStore.load()
        async let applications: Void = applicationStore.load()
        _ = await (identities, applications)
    }

    private var notificationBridge: NotificationBridge {
        NotificationBridge(
            isDenied: { notificationPermission.isDenied },
            refreshPermission: { await notificationPermission.refresh() },
            requestAndSchedule: {
                let granted = await notificationPermission.requestAuthorization()
                guard granted else { return }
                await notificationScheduler.reschedule(
                    identityStore: identityStore,
                    applicationStore: applicationStore
                )
            },
            rescheduleIfAuthorized: { await rescheduleNotificationsIfAuthorized() },
            openSettings: {
                guard let url = notificationPermission.settingsURL else { return }
                UIApplication.shared.open(url)
            }
        )
    }

    private func rescheduleNotificationsIfAuthorized() async {
        await notificationPermission.refresh()
        guard notificationPermission.isAuthorized else { return }
        await notificationScheduler.reschedule(
            identityStore: identityStore,
            applicationStore: applicationStore
        )
    }
}
