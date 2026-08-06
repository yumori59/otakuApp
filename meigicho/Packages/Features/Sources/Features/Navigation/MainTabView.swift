import SwiftUI
import DesignSystem
import Domain

public struct MainTabView: View {
    @Environment(\.themeStore) private var theme
    @Environment(DeepLinkCoordinator.self) private var deepLink
    @State private var selectedTab: AppTab = .home

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            HomeTab()
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.icon) }
                .tag(AppTab.home)

            IdentitiesTab()
                .tabItem { Label(AppTab.identities.title, systemImage: AppTab.identities.icon) }
                .tag(AppTab.identities)

            ApplicationsTab()
                .tabItem { Label(AppTab.applications.title, systemImage: AppTab.applications.icon) }
                .tag(AppTab.applications)
        }
        .tint(theme.primary)
        .onChange(of: deepLink.pending?.tab) { _, tab in
            if let tab { selectedTab = tab }
        }
    }
}

#Preview("ゲスト（未ログイン）") {
    // 未ログインでもタブに入れる（Q5）。各タブは案内カードを出す
    MainTabView()
        .environment(IdentityStore())
        .environment(ApplicationStore())
        .environment(AppSettingsStore())
        .environment(AuthStore.preview(state: .signedOut))
        .environment(ProfileStore())
        .environment(ShareLinkStore())
        .environment(SheetPresenter())
        .environment(\.themeStore, ThemeStore())
}

#Preview("ログイン済み") {
    // Preview は SampleData（Domain/Preview）を直接注入する。実行時経路では使わない。
    let identityStore = IdentityStore(now: { SampleData.referenceDate })
    identityStore.identities = SampleData.identities
    identityStore.memberships = SampleData.memberships
    let applicationStore = ApplicationStore(now: { SampleData.referenceDate })
    applicationStore.tours = SampleData.tours
    applicationStore.events = SampleData.events
    applicationStore.applications = SampleData.applications

    return MainTabView()
        .environment(identityStore)
        .environment(applicationStore)
        .environment(AppSettingsStore())
        .environment(AuthStore.preview(state: .signedIn))
        .environment(ProfileStore())
        .environment(ShareLinkStore())
        .environment(SheetPresenter())
        .environment(\.themeStore, ThemeStore())
}
