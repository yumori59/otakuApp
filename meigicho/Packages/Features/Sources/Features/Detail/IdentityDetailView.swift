import SwiftUI
import DesignSystem
import Domain
import Core

struct IdentityDetailView: View {
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(StatsStore.self) private var statsStore
    @Environment(SheetPresenter.self) private var sheetPresenter
    @Environment(\.themeStore) private var theme
    @Environment(\.notificationBridge) private var notifications
    @Binding var path: NavigationPath
    let identityID: UUID
    @State private var isEditingNote = false
    @State private var draftNote = ""
    @FocusState private var noteFocused: Bool
    @State private var pickedColor: Color = .blue
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false

    private var identity: Identity? { identityStore.identity(for: identityID) }

    var body: some View {
        ScrollView {
            if let identity {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = identityStore.actionError {
                        ErrorBar(error.userMessage) { identityStore.actionError = nil }
                    }
                    profileCard(identity)
                    noteSection(identity)
                    shareSection(identity)
                    membershipsSection(identity)
                    applicationsSection(identity)
                    deleteButton()
                }
                .padding(16)
            } else {
                EmptyStateView("名義が見つかりません")
            }
        }
        .background(theme.bgApp)
        .navigationTitle("名義詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if identity != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("編集") {
                        sheetPresenter.activeSheet = .editIdentity(id: identityID)
                    }
                }
            }
        }
        .onAppear {
            if let identity { pickedColor = Color(hexString: identity.colorHex) }
        }
        .confirmationDialog(
            "「\(identity?.displayName ?? "")」を削除しますか？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除する", role: .destructive) {
                Task { await deleteIdentity() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            if let identity {
                Text(deleteConfirmationMessage(for: identity))
            }
        }
    }

    /// FR-DEL-7: 会員情報件数はこの名義に属する会員情報、申込件数は**この名義を代表とする**申込
    /// （同行者としての参加は含めない = FR-DEL-8 が保持対象）。`IdentityStore` から
    /// `ApplicationStore` へは参照しないため、件数の合成は View 側で行う。
    ///
    /// `applicationStore.applications` はページング読み込み結果のローカル配列。通常は起動時の
    /// `load()` が `has_more == false` になるまで辿るため全件そろうが、①まだ読み込みが完了していない
    /// （`applicationsState != .loaded`）②上限 4,000 件で打ち切られた（`truncated`）場合は
    /// 実データより少ない件数になりうる。件数を偽って見せないよう、その2ケースは件数無しの文言にする。
    private func deleteConfirmationMessage(for identity: Identity) -> String {
        let membershipCount = identityStore.memberships(for: identity.id).count
        guard applicationStore.applicationsState == .loaded, !applicationStore.truncated else {
            return "会員情報 \(membershipCount) 件も一緒に削除されます。申込の記録は残ります。"
        }
        let repApplicationCount = applicationStore.applications(for: identity.id)
            .filter { $0.repIdentityID == identity.id }
            .count
        return "会員情報 \(membershipCount) 件も一緒に削除されます。申込 \(repApplicationCount) 件の記録は残ります。"
    }

    /// 削除実行。成功したら画面を閉じて呼び出し元へ戻り、通知を再スケジュールする（IOS-13 に配慮し
    /// リポジトリの完了後にのみローカル状態と画面遷移を進める）。失敗時は画面を閉じず `actionError`
    /// の表示に任せる（`identityStore.deleteIdentity` が設定する）。
    private func deleteIdentity() async {
        isDeleting = true
        let ok = await identityStore.deleteIdentity(identityID)
        isDeleting = false
        guard ok else { return }
        if !path.isEmpty {
            path.removeLast()
        }
        await notifications.rescheduleIfAuthorized()
    }

    private func deleteButton() -> some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Text("この名義を削除")
                .font(DSFont.bodyBold)
                .foregroundStyle(DS.error)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
        .padding(.top, 8)
    }

    private func profileCard(_ identity: Identity) -> some View {
        VStack(spacing: 12) {
            ProfileCard(
                initial: identity.displayName,
                colorHex: identity.colorHex,
                name: identity.displayName,
                tag: identity.relation.label,
                stats: "入会 \(DateFormatting.formatDate(identity.joinedOn, withWeekday: false)) ・ 当選 \(statsStore.winCount(for: identity.id, fallback: applicationStore.winCount(for: identity.id)))回"
            )
            HStack {
                Text("名義カラー").font(DSFont.caption).foregroundStyle(DS.Gray.g600)
                Spacer()
                ColorPicker("", selection: $pickedColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: pickedColor) { _, new in
                        identityStore.updateIdentityColor(identity.id, colorHex: new.hexString)
                    }
            }
            .padding(.horizontal, 4)
            FormHint("一覧やツアー表でこの名義を見分けるための色分けです（背景色には反映されません）")
        }
    }

    private func noteSection(_ identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("備考")
            if isEditingNote {
                TextEditor(text: $draftNote)
                    .font(DSFont.body)
                    .frame(minHeight: 76)
                    .padding(10)
                    .background(DS.Gray.g100)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                    .focused($noteFocused)
                    .onChange(of: noteFocused) { _, focused in
                        if !focused {
                            identityStore.updateIdentityNote(identity.id, note: draftNote)
                            isEditingNote = false
                        }
                    }
            } else {
                Button {
                    draftNote = identity.note
                    isEditingNote = true
                    noteFocused = true
                } label: {
                    Text(identity.note.isEmpty ? "タップして備考を追加" : identity.note)
                        .font(DSFont.caption)
                        .foregroundStyle(identity.note.isEmpty ? DS.Gray.g400 : DS.Gray.g600)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(DS.Gray.g100)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func shareSection(_ identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("共有設定")
            SwitchRow(
                title: "当落履歴を共有時に公開する",
                hint: "オフにすると、共有プレビューでこの名義の当落履歴が非公開になります",
                isOn: Binding(
                    get: { identity.historyVisible },
                    set: { _ in identityStore.toggleHistoryVisible(identity.id) }
                )
            )
        }
    }

    private func membershipsSection(_ identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("ファンクラブ会員情報")
            ForEach(identityStore.memberships(for: identity.id)) { m in
                Button {
                    sheetPresenter.activeSheet = .editMembership(id: m.id)
                } label: {
                    MembershipCard(
                        fcName: m.fanClubNameRaw,
                        memberNoLast4: m.memberNoLast4,
                        renewalOn: m.renewalOn,
                        feeYen: m.feeYen,
                        today: identityStore.today
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            AddRowButton("会員情報を追加") {
                sheetPresenter.activeSheet = .addMembership(identityID: identity.id)
            }
        }
    }

    private func applicationsSection(_ identity: Identity) -> some View {
        let apps = applicationStore.sortedByEventDate(applicationStore.applications(for: identityID)).reversed()
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader("申込履歴")
            if apps.isEmpty {
                EmptyStateView("この名義ではまだ申込がありません")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(apps)) { app in
                        ApplicationTicketRow(app: app, contextIdentityID: identityID) {
                            path.append(AppRoute.application(app.id))
                        }
                    }
                }
            }
            // 「申込履歴」リストの後、画面最下部にインラインバナー 1 枚（docs/07 §7.2 / F2-5）
            PlacementAdSlot(placement: .identityDetailBottom)
                .padding(.top, 8)
        }
    }
}
