import SwiftUI
import DesignSystem
import Domain
import Core

struct HomeTab: View {
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(AppSettingsStore.self) private var appSettings
    @Environment(AuthStore.self) private var auth
    @Environment(ProfileStore.self) private var profile
    @Environment(SheetPresenter.self) private var sheetPresenter
    @Environment(HomeStore.self) private var homeStore
    /// ローカルファースト同期の状態（ios-sync-engine T4）。失敗時のみ 1 行表示する（AC-SY-06）
    @Environment(SyncStatusStore.self) private var syncStatus
    @Environment(\.themeStore) private var theme
    @Environment(\.notificationBridge) private var notifications
    @Environment(\.syncActionBridge) private var syncAction
    @State private var path = NavigationPath()
    @State private var showActionSheet = false
    /// 共有リンクを受け取った人の入口（URL 貼り付け）。**未ログインでも使える**（T4b / §7.7）
    @State private var showOpenSharedBoard = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    homeHeader
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(theme.bgApp)
            .refreshable {
                // 未ログインでは Bearer が無く 401 になるだけなので呼ばない（Q5）
                guard !auth.isGuest else { return }
                async let apps: Void = applicationStore.load()
                async let ids: Void = identityStore.load()
                async let home: Void = homeStore.load()
                _ = await (apps, ids, home)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { path.append(AppRoute.account) } label: {
                        Image(systemName: "person.circle").font(.system(size: 22))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .topBarLeading) {
                    // 共有リンクを受け取った人の入口。ログイン状態に依存しない（Bearer を使わない経路）
                    Button { showOpenSharedBoard = true } label: {
                        Image(systemName: "link").font(.system(size: 19))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("共有リンクを開く")
                }
                ToolbarItem(placement: .principal) {
                    Text("ホーム").font(DSFont.bodyBold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // 未ログインなら選択肢を出さず、そのままログインへ誘導する（Q5）
                        if auth.isGuest {
                            sheetPresenter.presentSignIn(reason: SignInPrompt.addAny)
                        } else {
                            showActionSheet = true
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .appNavigationDestinations(path: $path)
            .task { await notifications.refreshPermission() }
            .confirmationDialog("追加", isPresented: $showActionSheet, titleVisibility: .visible) {
                Button("名義を追加") {
                    sheetPresenter.presentAddIdentity(
                        auth: auth,
                        profile: profile,
                        identityCount: identityStore.identities.count
                    )
                }
                Button("申込を追加") {
                    sheetPresenter.present(.addApplication, requiringSignIn: auth, reason: SignInPrompt.addApplication)
                }
                Button("キャンセル", role: .cancel) {}
            }
            .sheet(item: sheetBinding) { sheet in
                SheetContentView(sheet: sheet) { id in
                    path.append(AppRoute.identity(id))
                }
            }
            .sheet(isPresented: $showOpenSharedBoard) {
                OpenSharedBoardView()
            }
        }
    }

    private var sheetBinding: Binding<AppSheet?> {
        Binding(
            get: { sheetPresenter.activeSheet },
            set: { sheetPresenter.activeSheet = $0 }
        )
    }

    /// 未ログイン（ゲスト）は**案内カードだけ**を出す。
    /// 集計値（0 件）を並べると「登録が消えた」と誤解させるため出さない（Q5）。
    @ViewBuilder
    private var content: some View {
        if auth.isGuest {
            SignInPromptCard(message: SignInPrompt.home) {
                sheetPresenter.presentSignIn()
            }
        } else {
            signedInContent
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        // ローカルファースト同期が失敗しているときだけ 1 行表示（成功は出さない・モーダル禁止 — AC-SY-06）
        if case .failed(let message) = syncStatus.status {
            ErrorBar(message) {
                Task { await syncAction.retry() }
            }
            .padding(.bottom, 12)
        }
        // 読み込み済みの内容は消さず、1 行のエラーバーだけを出す（E-1）
        if let error = applicationStore.applicationsState.error {
            ErrorBar(error.userMessage) {
                Task { await applicationStore.load() }
            }
            .padding(.bottom, 12)
        }
        if notifications.isDenied() {
            Button {
                notifications.openSettings()
            } label: {
                FormHint("通知がオフです。更新期限と当落発表をお知らせできません。設定アプリから有効にできます。")
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        // 3 指標は BE `GET /v1/home/summary`。未取得時はローカル集計にフォールバック
        StatRow(cards: statCards).padding(.bottom, 16)
        SectionHeader("直近のイベント")
        upcomingSection
        SectionHeader("当落発表待ちの申込")
        pendingSection
        // 「当落発表待ちの申込」リストの**後**、画面最下部にネイティブ 1 枚
        // （F2-1 / docs/07 §7.2）。`stat-row` の直下には置かない
        PlacementAdSlot(placement: .homeBottom, format: .native)
            .padding(.top, 16)
    }

    private var homeHeader: some View {
        Group {
            if auth.isGuest {
                // 未ログインでは「アプリ名を登録する」（書き込み導線）を出さない
                BigTitle("参戦名義帳", subtitle: DateFormatting.formatDate(applicationStore.today))
            } else if let name = appSettings.appDisplayName {
                BigTitle(name, subtitle: DateFormatting.formatDate(applicationStore.today))
            } else {
                Button { path.append(AppRoute.account) } label: {
                    HStack(spacing: 6) {
                        Text("アプリ名を登録する")
                            .font(DSFont.bigTitle)
                            .foregroundStyle(DS.Gray.g400)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(DS.Gray.g400)
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                }
                .buttonStyle(.plain)
                Text(DateFormatting.formatDate(applicationStore.today))
                    .font(DSFont.caption)
                    .foregroundStyle(DS.Gray.g600)
                    .padding(.bottom, 18)
            }
        }
    }

    private var statCards: [(value: String, label: String)] {
        if let summary = homeStore.summary {
            return [
                ("\(summary.identityCount)", "管理中の名義"),
                ("\(summary.renewalsWithin30Days)", "30日以内に\n更新期限"),
                ("\(summary.pendingResults)", "当落発表\n待ち"),
            ]
        }
        return [
            ("\(identityStore.identities.count)", "管理中の名義"),
            ("\(identityStore.expiringMembershipCount())", "30日以内に\n更新期限"),
            ("\(applicationStore.pendingResultCount())", "当落発表\n待ち"),
        ]
    }

    @ViewBuilder
    private var upcomingSection: some View {
        let upcoming = applicationStore.upcomingWonEvents()
        if upcoming.isEmpty {
            EmptyStateView("当選して参戦が確定している公演はまだありません")
        } else {
            CardList {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, app in
                    upcomingRow(app)
                    if index < upcoming.count - 1 { Divider().padding(.leading, 70) }
                }
            }
        }
    }

    @ViewBuilder
    private var pendingSection: some View {
        let pending = applicationStore.awaitingResults()
        if pending.isEmpty {
            EmptyStateView("現在、発表待ちの申込はありません")
        } else {
            VStack(spacing: 0) {
                ForEach(pending) { app in
                    ApplicationTicketRow(app: app) {
                        path.append(AppRoute.application(app.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func upcomingRow(_ app: ApplicationEntry) -> some View {
        let rep = identityStore.identity(for: app.repIdentityID)
        let display = applicationStore.display(for: app)
        ListRow(
            avatarInitial: rep?.displayName ?? "?",
            avatarColor: rep?.colorHex ?? "#9C9CA8",
            title: display.eventName ?? "公演情報を読み込み中",
            subtitle: subtitle(display),
            trailing: display.eventDate.map { CountdownBadge.event(for: $0, today: applicationStore.today) }
        ) {
            path.append(AppRoute.application(app.id))
        }
    }

    private func subtitle(_ display: ApplicationDisplay) -> String {
        guard let venue = display.venueName, !venue.isEmpty else {
            return DateFormatting.formatDate(display.eventDate)
        }
        return "\(venue) ・ \(DateFormatting.formatDate(display.eventDate))"
    }
}
