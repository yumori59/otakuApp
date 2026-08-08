import SwiftUI
import DesignSystem
import Domain
import Core

/// 受信箱（**自分が招待された共有**の一覧）。`GET /v1/shares/received`。
///
/// - 正はサーバー（`SharedInboxStore`）。ローカル永続化しない
/// - 読み込み失敗でも直前まで表示していた一覧は消さない（E-1）。エラーは 1 行のバーで伝える
/// - スワイプで「非表示」（オーナーには見えない・冪等）。行タップで共有ボードを開く
struct SharedInboxView: View {
    @Environment(SharedInboxStore.self) private var store
    @Environment(\.themeStore) private var theme
    @Binding var path: NavigationPath

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            contentBody
        }
        .background(theme.bgApp)
        .navigationTitle("受信した共有")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 既に読み込み済み（タブの入口で先読みしている）なら二重に叩かない
            if store.state == .idle { await store.load() }
        }
    }

    // MARK: - ヘッダ（エラーバー含む・スクロールしない）

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            BigTitle("受信した共有")
            // 非表示切替の失敗。一覧は消さず、この 1 行で伝える
            if let error = store.actionError {
                ErrorBar(error.userMessage) { store.clearActionError() }
                    .padding(.bottom, 8)
            }
            // 読み込み失敗。既に表示している一覧があればそれは残したまま、再試行だけ促す（E-1）
            if case .failed(let error) = store.state {
                ErrorBar(error.userMessage) {
                    Task { await store.load() }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 本体

    @ViewBuilder
    private var contentBody: some View {
        if store.items.isEmpty {
            ScrollView {
                emptyContent
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
            }
        } else {
            List {
                ForEach(store.items) { item in
                    row(item)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.load() }
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        if store.state.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 32)
        } else if case .failed = store.state {
            EmptyStateView("受信した共有を読み込めませんでした")
        } else {
            EmptyStateView("まだ共有の招待はありません。\nオーナーにあなたの ACC-ID を伝えると、ここに表示されます。")
        }
    }

    // MARK: - 行

    private func row(_ item: SharedInboxItem) -> some View {
        ListRow(
            avatarInitial: item.owner.displayLabel,
            avatarColor: "#9C9CA8",
            title: item.displayTitle,
            subtitle: "\(item.owner.displayLabel) ・ \(item.permission.label)",
            meta: metaText(for: item),
            trailing: item.unread ? AnyView(unreadDot) : nil
        ) {
            // board を開く前に手元の未読を落とす。正はサーバー（次の load で上書きされる）
            store.markRead(shareID: item.shareID)
            path.append(AppRoute.sharedBoard(shareID: item.shareID))
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await store.setHidden(shareID: item.shareID, hidden: true) }
            } label: {
                Label("非表示にする", systemImage: "eye.slash")
            }
        }
    }

    private var unreadDot: some View {
        Circle().fill(theme.primary).frame(width: 8, height: 8)
    }

    private func metaText(for item: SharedInboxItem) -> String {
        var parts = ["招待 " + DateFormatting.formatDateShort(item.invitedAt)]
        if let expiresAt = item.expiresAt {
            parts.append("期限 " + DateFormatting.formatDateShort(expiresAt))
        }
        return parts.joined(separator: " ・ ")
    }
}

#Preview("受信あり") {
    NavigationStack {
        SharedInboxView(path: .constant(NavigationPath()))
    }
    .environment(SharedInboxStore(repository: InMemorySharedInboxRepository()))
    .environment(\.themeStore, ThemeStore())
}

#Preview("空") {
    NavigationStack {
        SharedInboxView(path: .constant(NavigationPath()))
    }
    .environment(SharedInboxStore(repository: InMemorySharedInboxRepository(items: [])))
    .environment(\.themeStore, ThemeStore())
}
