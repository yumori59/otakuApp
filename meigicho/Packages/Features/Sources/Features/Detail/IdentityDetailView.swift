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
    @Binding var path: NavigationPath
    let identityID: UUID
    @State private var isEditingNote = false
    @State private var draftNote = ""
    @FocusState private var noteFocused: Bool
    @State private var pickedColor: Color = .blue

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
                }
                .padding(16)
            } else {
                EmptyStateView("名義が見つかりません")
            }
        }
        .background(theme.bgApp)
        .navigationTitle("名義詳細")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let identity { pickedColor = Color(hexString: identity.colorHex) }
        }
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
                MembershipCard(
                    fcName: m.fanClubNameRaw,
                    memberNoLast4: m.memberNoLast4,
                    renewalOn: m.renewalOn,
                    feeYen: m.feeYen,
                    today: identityStore.today
                )
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
