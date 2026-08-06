import SwiftUI
import DesignSystem
import Domain
import Core

struct ApplicationsTab: View {
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(AuthStore.self) private var auth
    @Environment(ShareLinkStore.self) private var shareLinks
    @Environment(SheetPresenter.self) private var sheetPresenter
    @Environment(DeepLinkCoordinator.self) private var deepLink
    @Environment(\.themeStore) private var theme
    @State private var path = NavigationPath()
    @State private var filter: ApplicationFilter = .all
    @State private var searchText = ""
    @State private var viewMode: ApplicationViewMode = .list

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BigTitle("申込")
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(theme.bgApp)
            .refreshable {
                // 未ログインでは Bearer が無く 401 になるだけなので呼ばない（Q5）
                guard !auth.isGuest else { return }
                await applicationStore.load()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("申込").font(DSFont.bodyBold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // 未ログインならフォームを開かずログインへ誘導する（Q5）
                        sheetPresenter.present(
                            .addApplication,
                            requiringSignIn: auth,
                            reason: SignInPrompt.addApplication
                        )
                    } label: {
                        Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .appNavigationDestinations(path: $path)
            .onChange(of: deepLink.pending) { _, _ in
                if let route = deepLink.consume(for: .applications) {
                    path.append(route)
                }
            }
            .sheet(item: sheetBinding) { sheet in
                SheetContentView(sheet: sheet) { _ in }
            }
            // 共有リンクの状態は `GET /v1/shares` だけが正（ローカルに持たない）。
            // ツアー表を開いたときにだけ取りに行く（未ログインでは Bearer が無いので呼ばない）
            .onChange(of: viewMode) { _, mode in
                guard mode == .tourTable, !auth.isGuest else { return }
                Task { await shareLinks.load() }
            }
            .task(id: auth.state) {
                guard viewMode == .tourTable, !auth.isGuest else { return }
                await shareLinks.load()
            }
        }
    }

    /// 未ログイン（ゲスト）は**案内カードだけ**を出す。
    /// 絞り込みも検索も、表示するデータが無い状態では意味を持たない（Q5）。
    @ViewBuilder
    private var content: some View {
        if auth.isGuest {
            SignInPromptCard(message: SignInPrompt.applications) {
                sheetPresenter.presentSignIn()
            }
            .padding(.top, 8)
        } else {
            signedInContent
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        // 既に読み込んだ内容は消さず、1 行のエラーバーだけを出す（E-1 / AC-AP-11-M）
        if let error = applicationStore.applicationsState.error {
            ErrorBar(error.userMessage) {
                Task { await applicationStore.load() }
            }
            .padding(.bottom, 12)
        }
        if applicationStore.truncated {
            // E-9: 打ち切り。表示件数の上限に達したことを隠さない
            FormHint("件数が多いため一部のみ表示しています。絞り込んでご確認ください。")
                .padding(.bottom, 12)
        }

        SegmentedPicker(
            options: [(ApplicationViewMode.list, "リスト"), (.tourTable, "ツアー表")],
            selection: $viewMode
        )

        if viewMode == .list {
            filterChips
            searchField
            listContent
        } else {
            tourTableContent
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(DS.Gray.g400)
            TextField("公演名・会場で検索", text: $searchText).font(DSFont.body)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
        .padding(.bottom, 16)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ApplicationFilter.allCases, id: \.self) { item in
                    Button { filter = item } label: {
                        Text(item.rawValue)
                            .font(DSFont.caption)
                            .foregroundStyle(filter == item ? .white : DS.Gray.g600)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(filter == item ? theme.primary : DS.Gray.g100)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        let apps = applicationStore.filteredApplications(filter: filter, search: searchText)
        if apps.isEmpty {
            // 「空データ」と「まだ読めていない」を区別する（E-1）
            if applicationStore.applicationsState.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else if applicationStore.applicationsState.error != nil {
                EmptyStateView("申込を読み込めませんでした")
            } else {
                EmptyStateView("該当する申込がありません")
            }
        } else {
            VStack(spacing: 0) {
                ForEach(apps) { app in
                    ApplicationTicketRow(app: app) {
                        path.append(AppRoute.application(app.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var tourTableContent: some View {
        let groups = applicationStore.allTourGroups()
        if groups.isEmpty {
            if applicationStore.applicationsState.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
            } else if applicationStore.applicationsState.error != nil {
                EmptyStateView("申込を読み込めませんでした")
            } else {
                EmptyStateView("申込データがありません")
            }
        } else {
            VStack(spacing: 20) {
                // ツアー表は状況・座席をその場で更新できる。失敗は 1 行で伝える（E-7）
                if let error = applicationStore.writeError {
                    ErrorBar(error.userMessage) { applicationStore.clearWriteError() }
                }
                if let error = shareLinks.state.error {
                    ErrorBar(error.userMessage) { Task { await shareLinks.load() } }
                }
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    TourGroupView(group: group, path: $path)
                    // `tour-group` と `tour-group` の**間**に全体で 1 枚だけ（F2-4 / docs/07 §7.2）。
                    // 表（Grid）の内側には絶対に入れない。グループが 1 つしか無いときは出さない
                    if index == 0, groups.count > 1 {
                        PlacementAdSlot(placement: .tourTableBetween)
                    }
                }
            }
        }
    }

    private var sheetBinding: Binding<AppSheet?> {
        Binding(get: { sheetPresenter.activeSheet }, set: { sheetPresenter.activeSheet = $0 })
    }
}

struct ApplicationTicketRow: View {
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    let app: ApplicationEntry
    var contextIdentityID: UUID? = nil
    let action: () -> Void

    var body: some View {
        let rep = identityStore.identity(for: app.repIdentityID)
        let display = applicationStore.display(for: app)
        TicketRowView(
            event: display.eventName ?? "公演情報を読み込み中",
            meta: metaText(display),
            tags: buildTags(repName: rep?.displayName ?? "不明"),
            status: mapStatus(app.status),
            stubText: stubText,
            action: action
        )
    }

    private func metaText(_ display: ApplicationDisplay) -> String {
        // 会場が未解決なら空文字で埋めず、日付だけを出す
        guard let venue = display.venueName, !venue.isEmpty else {
            return DateFormatting.formatDate(display.eventDate)
        }
        return "\(venue) ・ \(DateFormatting.formatDate(display.eventDate))"
    }

    private var stubText: String {
        if app.status == .won, !app.seatRaw.isEmpty { return app.seatRaw }
        return "発表 \(DateFormatting.formatDateShort(app.resultOn))"
    }

    private func buildTags(repName: String) -> [TagView] {
        var tags: [TagView] = []
        if let ctx = contextIdentityID {
            if ctx == app.repIdentityID {
                tags.append(TagView("代表者として申込", kind: .rep))
                if !app.companions.isEmpty {
                    tags.append(TagView("同行者: \(companionNames)", kind: .companion))
                }
            } else {
                tags.append(TagView("同行者として参加（代表: \(repName)）", kind: .companion))
            }
        } else {
            tags.append(TagView("代表: \(repName)", kind: .rep))
            if !app.companions.isEmpty {
                tags.append(TagView("同行者: \(companionNames)", kind: .companion))
            }
        }
        return tags
    }

    private var companionNames: String {
        app.companions.map(\.displayName).joined(separator: "、")
    }

    private func mapStatus(_ status: ApplicationStatus) -> StampView.Status {
        switch status {
        case .draft: .draft
        case .applied: .applied
        case .won: .won
        case .lost, .cancelled: .lost
        }
    }
}

/// ツアー 1 本ぶんの表 + 共有状態（**オーナー側**）。
///
/// **表に描くのは常にローカルの申込データ**（AC-SH-12）。共有ペイロード
/// （`GET /public/shares/:token`）はオーナー側から取りに行かない。
/// 共有相手が編集した内容は「最新を取得」= `GET /v1/applications` の再取得で反映される。
///
/// 状況・座席のその場編集は**通常の申込 PATCH**（`ApplicationStore`）に流す。
/// 旧 `TourShareStore.cycleSharedStatus` / `saveSharedSeat`（UserDefaults 上のモック）は廃止した。
struct TourGroupView: View {
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(AuthStore.self) private var auth
    @Environment(ShareLinkStore.self) private var shareLinks
    @Environment(SheetPresenter.self) private var sheetPresenter
    /// 当落ステータス切り替え後 60 秒の広告クールダウン（F4-5）の起点を記録するためだけに参照する
    @Environment(AdsStore.self) private var adsStore

    let group: ApplicationStore.TourGroup
    @Binding var path: NavigationPath

    @State private var editingSeatID: UUID?
    @State private var draftSeat = ""
    @State private var isRefreshing = false

    /// 未共有 / 共有中 / 共有終了 の 3 状態（`ShareLinkStore`）。
    private var shareState: ShareLinkState { shareLinks.shareState(forTour: group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                localTable
            }
            if groupHasDuplicateEvents {
                FormHint("同じ公演に複数の申込があります。代表者を入れ替えた意図的な重複か確認してください。")
            }
            FormHint("状況と座席はこの表で直接編集できます。共有相手が書き込んだ内容は「最新を取得」で反映されます。")
        }
    }

    // MARK: - ヘッダー（共有の状態）

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(group.tourName).font(DSFont.bodyBold)
                Spacer()
                statusBadge
            }
            Text(countsLine)
                .font(DSFont.caption).foregroundStyle(DS.Gray.g600)
            if let link = shareState.link {
                Text(shareDetailLine(link))
                    .font(DSFont.caption).foregroundStyle(DS.Gray.g600)
            }
            actionButtons
        }
    }

    private var countsLine: String {
        let winN = group.items.filter { $0.status == .won }.count
        let pendN = group.items.filter { $0.status == .applied }.count
        let loseN = group.items.filter { $0.status == .lost }.count
        return "全\(group.items.count)件・当選\(winN)／申込中\(pendN)／落選\(loseN)"
    }

    private var groupHasDuplicateEvents: Bool {
        let duplicateIDs = applicationStore.duplicateEventIDs()
        return group.items.contains { duplicateIDs.contains($0.eventID) }
    }

    /// `編集も許可 ・ 閲覧 3 回 ・ 編集 2 回 ・ 期限 2026年8月31日`（AC-SH-07-M）。
    private func shareDetailLine(_ link: Domain.ShareLink) -> String {
        var parts = [link.permissionLabel, link.accessCountsSummary]
        if case .ended = shareState {
            parts.append("共有は終了しました")
        } else if let expiresAt = link.expiresAt {
            parts.append("期限 \(DateFormatting.formatDate(expiresAt, withWeekday: false))")
        }
        return parts.joined(separator: " ・ ")
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            switch shareState {
            case .shared:
                TourActionButton(isRefreshing ? "取得中…" : "最新を取得", icon: "arrow.clockwise") {
                    Task { await refreshFromServer() }
                }
                TourActionButton("共有の設定") { presentShareSheet() }
            case .ended:
                TourActionButton("もう一度共有する") { presentShareSheet() }
            case .unshared:
                TourActionButton("共有相手を選んで共有する") { presentShareSheet() }
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch shareState {
        case .shared:
            badge("共有中", color: DS.success, background: DS.successBG)
        case .ended:
            badge("共有終了", color: DS.Gray.g600, background: DS.Gray.g100)
        case .unshared:
            badge("未共有", color: DS.Gray.g600, background: DS.Gray.g100)
        }
    }

    private func badge(_ text: String, color: Color, background: Color) -> some View {
        Text(text).font(DSFont.captionBold).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(background).clipShape(Capsule())
    }

    /// 未ログインならフォームを開かずログインへ誘導する（Q5 / T1c）。
    private func presentShareSheet() {
        sheetPresenter.present(
            .shareRecipients(tourName: group.tourName),
            requiringSignIn: auth,
            reason: SignInPrompt.share
        )
    }

    /// AC-SH-12-M: 共有先の編集は**申込の再取得**で取り込む（共有ペイロードは見に行かない）。
    private func refreshFromServer() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await applicationStore.load()
        await shareLinks.load()
    }

    // MARK: - 表（常にローカルデータ）

    private var localTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                tableHeader("公演"); tableHeader("代表者"); tableHeader("同行者"); tableHeader("状況"); tableHeader("座席")
            }
            .background(DS.Gray.g100)
            ForEach(group.items) { app in
                GridRow {
                    tableCell(eventCell(app).onTapGesture { path.append(AppRoute.application(app.id)) })
                    tableCell(repCell(app))
                    tableCell(companionCell(app))
                    tableCell(statusCell(app))
                    tableCell(seatCell(app))
                }
                .background(DS.surface)
            }
        }
        .font(DSFont.caption)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
        .frame(minWidth: 560)
    }

    /// タップで 下書き → 申込中 → 当選 → 落選 → 下書き。
    /// **`status` だけを PATCH する**ので、落選に戻しても座席は消えない（AC-AP-08-M）。
    private func statusCell(_ app: ApplicationEntry) -> some View {
        Button {
            // 当落が動いた瞬間から 60 秒は全広告を止める（F4-5 / AC-AD-39）。
            // PATCH の成否を待たずタップ時点で記録する（喜び/落胆の瞬間に枠を出さないことが目的）
            adsStore.recordStatusChange()
            Task { await applicationStore.updateApplicationStatus(app.id, status: Self.nextStatus(app.status)) }
        } label: {
            Text(app.status.label).font(DSFont.captionBold)
                .foregroundStyle(stampColor(app.status))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(stampBG(app.status))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    /// 巡回順。**`cancelled` は入れない**（取消は詳細画面から行う操作で、誤タップで入ると戻しにくい）。
    static func nextStatus(_ current: ApplicationStatus) -> ApplicationStatus {
        let order: [ApplicationStatus] = [.draft, .applied, .won, .lost]
        guard let index = order.firstIndex(of: current) else { return .applied }
        return order[(index + 1) % order.count]
    }

    @ViewBuilder
    private func seatCell(_ app: ApplicationEntry) -> some View {
        if editingSeatID == app.id {
            TextField("座席", text: $draftSeat)
                .font(DSFont.caption)
                .onSubmit {
                    let value = draftSeat
                    editingSeatID = nil
                    Task { await applicationStore.updateApplicationSeat(app.id, seat: value) }
                }
        } else {
            Button(app.seatRaw.isEmpty ? "未登録" : app.seatRaw) {
                draftSeat = app.seatRaw
                editingSeatID = app.id
            }
            .font(DSFont.caption)
            .foregroundStyle(DS.Gray.g900)
            .underline()
        }
    }

    private func repCell(_ app: ApplicationEntry) -> some View {
        let rep = identityStore.identity(for: app.repIdentityID)
        return HStack(spacing: 4) {
            ColorDot(rep?.colorHex)
            Text(rep?.displayName ?? "不明")
        }
    }

    private func eventCell(_ app: ApplicationEntry) -> some View {
        let display = applicationStore.display(for: app)
        return VStack(alignment: .leading, spacing: 2) {
            Text(DateFormatting.formatDateShort(display.eventDate))
            Text(display.venueName ?? "").foregroundStyle(DS.Gray.g400)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func companionCell(_ app: ApplicationEntry) -> some View {
        if app.companions.isEmpty {
            Text("—").foregroundStyle(DS.Gray.g900)
        } else {
            Text(app.companions.map(\.displayName).joined(separator: "、")).foregroundStyle(DS.Gray.g900)
        }
    }

    private func tableHeader(_ text: String) -> some View {
        Text(text).font(DSFont.captionBold).foregroundStyle(DS.Gray.g600)
            .frame(minWidth: 100, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder
    private func tableCell(_ content: some View) -> some View {
        content.frame(minWidth: 100, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
    }

    private func stampColor(_ status: ApplicationStatus) -> Color {
        switch status {
        case .won: DS.success
        case .lost, .cancelled: DS.Gray.g600
        case .draft: DS.Gray.g500
        case .applied: DS.warning
        }
    }

    private func stampBG(_ status: ApplicationStatus) -> Color {
        switch status {
        case .won: DS.successBG
        case .lost, .cancelled, .draft: DS.Gray.g100
        case .applied: DS.warningBG
        }
    }
}
