import SwiftUI
import DesignSystem
import Domain
import Core

struct ApplicationDetailView: View {
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(AuthStore.self) private var auth
    /// 当落ステータス切り替え後 60 秒の広告クールダウン（F4-5）の起点を記録するためだけに参照する。
    /// **この画面に広告枠は置かない**（F3 / AC-AD-35。禁止面のソース走査テストが機械的に担保する）
    @Environment(AdsStore.self) private var adsStore
    @Environment(SheetPresenter.self) private var sheetPresenter
    @Environment(\.themeStore) private var theme
    @Environment(\.notificationBridge) private var notifications
    @Binding var path: NavigationPath

    let applicationID: UUID
    @State private var isEditingSeat = false
    @State private var draftSeat = ""
    @FocusState private var seatFocused: Bool
    @State private var showDeleteConfirmation = false

    private var app: ApplicationEntry? { applicationStore.application(for: applicationID) }

    var body: some View {
        ScrollView {
            if let app {
                VStack(alignment: .leading, spacing: 16) {
                    // 保存に失敗したら値は巻き戻り、理由をここに出す
                    if let error = applicationStore.writeError {
                        ErrorBar(error.userMessage)
                    }
                    if applicationStore.isDuplicateEvent(app) {
                        duplicateWarning(for: app)
                    }
                    ticketHero(app)
                    statusChanger(app)
                    infoList(app)
                    if !app.note.isEmpty {
                        Text(app.note)
                            .font(DSFont.caption)
                            .foregroundStyle(DS.Gray.g600)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DS.Gray.g100)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                    }
                    deleteButton()
                }
                .padding(16)
            } else {
                EmptyStateView("申込が見つかりません")
            }
        }
        .background(theme.bgApp)
        .navigationTitle("申込詳細")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if app != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("編集") {
                        // 修正3（レビュー中4件）: 他の書き込み導線と同じくゲート越しにシートを開く（Q5）
                        sheetPresenter.present(
                            .editApplication(id: applicationID),
                            requiringSignIn: auth,
                            reason: SignInPrompt.editApplication
                        )
                    }
                }
            }
        }
        .task {
            applicationStore.clearWriteError()
            // 手元に無い公演は 1 件だけ取り直す（`contract-mapping.md` §4.6。空文字を描かない）
            if let app {
                await applicationStore.ensureEvent(id: app.eventID)
            }
        }
        .confirmationDialog(
            "この申込を削除しますか？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除する", role: .destructive) {
                Task { await deleteApplication() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("同行者の記録も一緒に削除されます。この操作は取り消せません。")
        }
    }

    /// 削除実行。成功したら画面を閉じて呼び出し元へ戻り、通知を再スケジュールする（IOS-13 に配慮し
    /// リポジトリの完了後にのみローカル状態と画面遷移を進める）。失敗時は画面を閉じず `writeError` の
    /// 表示に任せる（`applicationStore.deleteApplication` が設定する）。
    private func deleteApplication() async {
        let ok = await applicationStore.deleteApplication(applicationID)
        guard ok else { return }
        if !path.isEmpty {
            path.removeLast()
        }
        await notifications.rescheduleIfAuthorized()
    }

    private func ticketHero(_ app: ApplicationEntry) -> some View {
        // 公演情報が手元に無い場合は空文字を描かず「読み込み中」を出す（contract-mapping §4.6）
        let display = applicationStore.display(for: app)
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(display.artistName ?? "").font(DSFont.caption).foregroundStyle(.white.opacity(0.85))
                Text(display.eventName ?? "公演情報を読み込み中").font(DSFont.bodyBold).foregroundStyle(.white)
                Text(display.venueName ?? "").font(DSFont.caption).foregroundStyle(.white.opacity(0.85))
                Text(DateFormatting.formatDate(display.eventDate)).font(DSFont.captionBold).foregroundStyle(.white)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                StampView(status: mapStatus(app.status))
                    .scaleEffect(1.1)
                if !app.seatRaw.isEmpty {
                    Text(app.seatRaw).font(DSFont.caption).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center)
                }
            }
            .frame(width: 92)
            .padding(.vertical, 16)
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.3)).frame(width: 1.5) }
        }
        .background(theme.primary)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
    }

    private func statusChanger(_ app: ApplicationEntry) -> some View {
        HStack(spacing: 6) {
            ForEach([ApplicationStatus.draft, .applied, .won, .lost], id: \.self) { status in
                Button {
                    // 当落が動いた瞬間から 60 秒は全広告を止める（F4-5 / AC-AD-39）。
                    // **この画面自体は広告禁止面**（F3）なので広告枠は置かない。記録だけ行う
                    adsStore.recordStatusChange()
                    // `status` だけを PATCH する（落選に戻しても座席は消さない = R3-3）
                    Task { await applicationStore.updateApplicationStatus(app.id, status: status) }
                } label: {
                    Text(status.label)
                        .font(DSFont.caption)
                        .foregroundStyle(app.status == status ? statusColor(status) : DS.Gray.g600)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(app.status == status ? statusBG(status) : DS.Gray.g100)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
            }
        }
    }

    private func infoList(_ app: ApplicationEntry) -> some View {
        let rep = identityStore.identity(for: app.repIdentityID)
        return CardList {
            // FR-DEL-13: 代表者名義が削除済み（ローカルに存在しない）場合は行き止まりリンクにしない
            if let rep {
                infoLinkRow("代表者（FC名義）", value: rep.displayName) {
                    path.append(AppRoute.identity(app.repIdentityID))
                }
            } else {
                deletedIdentityRow("代表者（FC名義）")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("同行者").font(DSFont.caption).foregroundStyle(DS.Gray.g500)
                if app.companions.isEmpty {
                    Text("なし").font(DSFont.body).foregroundStyle(DS.Gray.g400)
                } else {
                    ForEach(app.companions) { c in
                        // FR-DEL-14: 表示名 (display_name) はそのまま出し、名義が削除済みならリンクだけ無効化する
                        if let id = c.identityID, identityStore.identity(for: id) != nil {
                            Button { path.append(AppRoute.identity(id)) } label: {
                                HStack {
                                    Spacer()
                                    Text("\(c.displayName) ›").font(DSFont.bodyBold).foregroundStyle(theme.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(c.displayName).font(DSFont.bodyBold).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            Divider()
            infoRow("申込日", value: DateFormatting.formatDate(app.appliedOn, withWeekday: false))
            Divider()
            infoRow("当落発表日", value: DateFormatting.formatDate(app.resultOn, withWeekday: false))
            Divider()
            seatRow(app)
        }
    }

    private func seatRow(_ app: ApplicationEntry) -> some View {
        HStack {
            Text("座席").font(DSFont.caption).foregroundStyle(DS.Gray.g500)
            Spacer()
            if isEditingSeat {
                TextField("座席", text: $draftSeat)
                    .font(DSFont.bodyBold.monospaced())
                    .multilineTextAlignment(.trailing)
                    .focused($seatFocused)
                    .onSubmit { saveSeat(app) }
                    .onChange(of: seatFocused) { _, focused in
                        if !focused { saveSeat(app) }
                    }
            } else {
                Text(app.seatRaw.isEmpty ? "未登録" : app.seatRaw)
                    .font(DSFont.bodyBold.monospaced())
                Button("編集") {
                    draftSeat = app.seatRaw
                    isEditingSeat = true
                    seatFocused = true
                }
                .font(DSFont.caption)
                .foregroundStyle(theme.primary)
            }
        }
        .padding(14)
    }

    private func saveSeat(_ app: ApplicationEntry) {
        isEditingSeat = false
        let seat = draftSeat
        Task { await applicationStore.updateApplicationSeat(app.id, seat: seat) }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(DSFont.caption).foregroundStyle(DS.Gray.g500)
            Spacer()
            Text(value).font(DSFont.bodyBold).multilineTextAlignment(.trailing)
        }
        .padding(14)
    }

    /// 削除済み名義の行（FR-DEL-13）。タップ不可・グレー表示。`infoRow` と違い値の色を弱める
    private func deletedIdentityRow(_ label: String) -> some View {
        HStack {
            Text(label).font(DSFont.caption).foregroundStyle(DS.Gray.g500)
            Spacer()
            Text("削除された名義").font(DSFont.bodyBold).foregroundStyle(DS.Gray.g400)
        }
        .padding(14)
    }

    private func deleteButton() -> some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Text("この申込を削除")
                .font(DSFont.bodyBold)
                .foregroundStyle(DS.error)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .disabled(applicationStore.isSaving)
        .padding(.top, 8)
    }

    private func infoLinkRow(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(DSFont.caption).foregroundStyle(DS.Gray.g500)
                Spacer()
                Text("\(value) ›").font(DSFont.bodyBold).foregroundStyle(theme.primary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mapStatus(_ status: ApplicationStatus) -> StampView.Status {
        switch status {
        case .draft: .draft
        case .applied: .applied
        case .won: .won
        case .lost, .cancelled: .lost
        }
    }

    private func statusColor(_ status: ApplicationStatus) -> Color {
        switch status {
        case .won: DS.success
        case .lost: DS.Gray.g600
        case .draft: DS.Gray.g500
        case .applied: DS.warning
        case .cancelled: DS.Gray.g600
        }
    }

    private func statusBG(_ status: ApplicationStatus) -> Color {
        switch status {
        case .won: DS.successBG
        case .lost, .draft, .cancelled: DS.Gray.g100
        case .applied: DS.warningBG
        }
    }

    private func duplicateWarning(for app: ApplicationEntry) -> some View {
        let others = applicationStore.coApplications(for: app.eventID).filter { $0.id != app.id }
        let otherNames = others.compactMap { identityStore.identity(for: $0.repIdentityID)?.displayName }
        let suffix = otherNames.isEmpty ? "" : "（他: \(otherNames.joined(separator: "、"))）"
        return FormHint("同じ公演に \(applicationStore.coApplications(for: app.eventID).count) 件の申込があります\(suffix)。代表者を入れ替えた意図的な重複か確認してください。")
    }
}
