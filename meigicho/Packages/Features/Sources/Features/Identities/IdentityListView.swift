import SwiftUI
import DesignSystem
import Domain
import Core

struct IdentitiesTab: View {
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(StatsStore.self) private var statsStore
    @Environment(AuthStore.self) private var auth
    @Environment(ProfileStore.self) private var profile
    @Environment(SheetPresenter.self) private var sheetPresenter
    @Environment(DeepLinkCoordinator.self) private var deepLink
    @Environment(\.themeStore) private var theme
    @State private var path = NavigationPath()
    @State private var sortOrder: IdentitySortOrder = .renewalSoon
    /// 名義追加シートを閉じた直後に続けて会員情報登録シートを開くための一時保持（AddIdentityView 保存直後）。
    /// `sheet(item:)` の同ティック内での差し替えはグリッチしうるため、`onDismiss` 完了を待ってから次を開く。
    @State private var pendingMembershipIdentityID: UUID?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BigTitle("名義")
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(theme.bgApp)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("名義").font(DSFont.bodyBold)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 2) {
                        // 未ログインなら画面を開かずログインへ誘導する（Q5）
                        Button {
                            if auth.isGuest {
                                sheetPresenter.presentSignIn(reason: SignInPrompt.share)
                            } else {
                                path.append(AppRoute.sharePreview)
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        Button {
                            sheetPresenter.presentAddIdentity(
                                auth: auth,
                                profile: profile,
                                identityCount: identityStore.identities.count
                            )
                        } label: {
                            Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                        }
                        .frame(minWidth: 44, minHeight: 44)
                    }
                }
            }
            .appNavigationDestinations(path: $path)
            .onChange(of: deepLink.pending) { _, _ in
                if let route = deepLink.consume(for: .identities) {
                    path.append(route)
                }
            }
            .sheet(item: sheetBinding, onDismiss: {
                guard let id = pendingMembershipIdentityID else { return }
                pendingMembershipIdentityID = nil
                sheetPresenter.activeSheet = .addMembership(identityID: id)
            }) { sheet in
                SheetContentView(sheet: sheet) { id in
                    pendingMembershipIdentityID = id
                    path.append(AppRoute.identity(id))
                }
            }
        }
    }

    /// 未ログイン（ゲスト）は**案内カードだけ**を出す。
    /// サーバーに保存が無いので並び替えも一覧も意味を持たない（Q5）。
    @ViewBuilder
    private var content: some View {
        if auth.isGuest {
            SignInPromptCard(message: SignInPrompt.identities) {
                sheetPresenter.presentSignIn()
            }
            .padding(.top, 8)
        } else {
            signedInContent
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        if let error = identityStore.actionError {
            ErrorBar(error.userMessage) { identityStore.actionError = nil }
                .padding(.bottom, 8)
        } else if let error = identityStore.identitiesState.error {
            ErrorBar(error.userMessage) {
                Task { await identityStore.load() }
            }
            .padding(.bottom, 8)
        }
        SegmentedPicker(
            options: IdentitySortOrder.allCases.map { ($0, $0.label) },
            selection: $sortOrder
        )
        let sorted = identityStore.sortedIdentities(
            by: sortOrder,
            winCounts: statsStore.winCounts(fallback: applicationStore.winCounts())
        )
        if sorted.isEmpty {
            EmptyStateView("まだ名義が登録されていません。\n右上の＋から追加できます。")
        } else {
            CardList {
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, identity in
                    identityRow(identity)
                    if index < sorted.count - 1 { Divider().padding(.leading, 70) }
                }
            }
            // card-list の後、画面最下部にインラインバナー 1 枚（docs/07 §7.2 / F2-2）
            PlacementAdSlot(placement: .identitiesBottom)
                .padding(.top, 16)
        }
    }

    private var sheetBinding: Binding<AppSheet?> {
        Binding(get: { sheetPresenter.activeSheet }, set: { sheetPresenter.activeSheet = $0 })
    }

    private func identityRow(_ identity: Identity) -> some View {
        let soonest = identityStore.nearestRenewal(for: identity.id)
        let names = identityStore.fanClubNames(for: identity.id)
        let fcNames = names.isEmpty ? "ファンクラブ未登録" : names.joined(separator: " / ")
        let wins = statsStore.winCount(
            for: identity.id,
            fallback: applicationStore.winCount(for: identity.id)
        )
        let joined = identity.joinedOn.map { DateFormatting.formatDateShort($0) } ?? "未定"

        return ListRow(
            avatarInitial: identity.displayName,
            avatarColor: identity.colorHex,
            title: identity.displayName,
            subtitle: fcNames,
            meta: "入会 \(joined) ・ 当選 \(wins)回",
            trailing: soonest.map { CountdownBadge.renewal(for: $0, today: identityStore.today) }
        ) {
            path.append(AppRoute.identity(identity.id))
        }
    }
}
