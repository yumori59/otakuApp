import SwiftUI
import DesignSystem
import Domain
import Core

/// 共有ボード（**受け取り側**）。`GET /public/shares/:token` の内容を表で見せ、
/// `permission == "write"` かつ `editable` な行だけ状況・座席を編集できる。
///
/// - このツリーは **Bearer 認証を一切使わない**（`SharedBoardStore` → `SharedBoardRepository`
///   → `PublicApiClient`）。開いたことで自分のアカウントがログアウトすることはない（AC-SB-13-M）
/// - `SharedBoardItem` は `ApplicationEntry` / `Identity` とは**別系統の型**。変換しない（P6）
/// - **`scope_type` で中身が別物**（P7）。`tour` は公演 × 名義の表、
///   `identity_summary` は名義ごとの件数一覧（**常に閲覧のみ**）
public struct SharedBoardView: View {
    @Environment(SharedBoardStore.self) private var store
    @Environment(\.themeStore) private var theme

    private let token: String

    @State private var editingSeatID: String?
    @State private var draftSeat = ""

    public init(token: String) {
        self.token = token
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle("共有ボード")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: token) {
            await store.open(token: token)
        }
    }

    // MARK: - ヘッダ

    @ViewBuilder
    private var header: some View {
        // identity_summary には tour 名が無い（`tour` キーごと来ない）
        let title = store.board?.displayTitle ?? "共有ボード"
        let subtitle = store.board.map { board in
            [board.artistName, "更新 " + DateFormatting.formatDate(board.generatedAt)]
                .compactMap { $0 }
                .joined(separator: " ・ ")
        }
        BigTitle(title, subtitle: subtitle)
    }

    // MARK: - 本体

    @ViewBuilder
    private var content: some View {
        if store.isEnded {
            // `SHARE_INVALID` 404。保存していた token は破棄済み（AC-SB-11-M）
            EmptyStateView("この共有は終了しました")
                .padding(.top, 24)
        } else {
            // **読み込み済みの表は消さない**。エラーバーを並べて出す（E-1 / `HomeView` と同じ扱い）
            if let error = store.state.error {
                ErrorBar(error.userMessage) {
                    Task { await store.reload() }
                }
                .padding(.bottom, 12)
            }

            if store.state.isLoading, store.board == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
            }

            if let board = store.board {
                if let error = store.actionError {
                    ErrorBar(error.userMessage) {
                        store.clearActionError()
                        Task { await store.reload() }
                    }
                    .padding(.bottom, 12)
                }

                permissionHint(board)
                boardContent(board)
            }
        }
    }

    /// `scope_type` で中身が別物なので、ここで分岐する（tour の表を identity_summary に流用しない）。
    @ViewBuilder
    private func boardContent(_ board: SharedBoard) -> some View {
        switch board.content {
        case .tour(let items):
            if items.isEmpty {
                EmptyStateView("共有されている公演がありません")
            } else {
                SectionHeader("公演")
                table(items)
            }
        case .identitySummary(let rows):
            if rows.isEmpty {
                EmptyStateView("共有されている名義がありません")
            } else {
                SectionHeader("名義")
                identitySummaryTable(rows)
            }
        }
    }

    @ViewBuilder
    private func permissionHint(_ board: SharedBoard) -> some View {
        // `read` リンクでは編集 UI を出さない（AC-SB-08-M）。押しても何も起きない要素を置かない
        switch board.content {
        case .tour:
            FormHint(
                board.permission == .write
                    ? "状況と座席だけ編集できます。編集内容は共有した相手にも反映されます。"
                    : "閲覧専用の共有です。"
            )
        case .identitySummary:
            // identity_summary に書き込み経路は無い（サーバー側も常に read）
            FormHint("名義ごとの申込数・当選数だけを共有しています。閲覧専用です。")
        }
    }

    // MARK: - 名義まとめ（identity_summary）

    /// 公演名・座席・同行者は**一切来ない**。名義名と件数だけを出す。
    /// `visible: false` の名義は件数キーごと来ないので「非公開」と表示する（0 件と書かない）。
    private func identitySummaryTable(_ rows: [SharedIdentitySummaryItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                tableHeader("名義")
                tableHeader("申込")
                tableHeader("当選")
            }
            .background(DS.Gray.g50)
            Divider()

            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 0) {
                    tableCell(
                        Text(row.name)
                            .font(DSFont.caption)
                            .foregroundStyle(DS.Gray.g900)
                    )
                    if let counts = row.counts {
                        tableCell(countCell("\(counts.applicationCount)"))
                        tableCell(countCell("\(counts.wonCount)"))
                    } else {
                        // 件数を 0 と書かない（非公開と 0 件は別物）
                        tableCell(hiddenCell)
                        tableCell(hiddenCell)
                    }
                }
                if index < rows.count - 1 { Divider() }
            }
        }
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }

    private func countCell(_ text: String) -> some View {
        Text(text).font(DSFont.captionBold).foregroundStyle(DS.Gray.g900)
    }

    private var hiddenCell: some View {
        Text("非公開").font(DSFont.caption).foregroundStyle(DS.Gray.g400)
    }

    // MARK: - 表（tour）

    private func table(_ items: [SharedBoardItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    tableHeader("公演")
                    tableHeader("名義")
                    tableHeader("同行")
                    tableHeader("状況")
                    tableHeader("座席")
                }
                .background(DS.Gray.g50)
                Divider()

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            tableCell(eventCell(item))
                            tableCell(repCell(item))
                            tableCell(companionCell(item))
                            tableCell(statusCell(item))
                            tableCell(seatCell(item))
                        }
                        // 409 / 403 はその行にだけ出す（ボード全体を作り直さない）
                        if let message = store.message(for: item) {
                            Text(message)
                                .font(DSFont.caption)
                                .foregroundStyle(DS.warning)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 8)
                        }
                    }
                    if index < items.count - 1 { Divider() }
                }
            }
            .background(DS.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
        }
    }

    private func eventCell(_ item: SharedBoardItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.eventName).font(DSFont.caption)
            Text([item.venue, item.roundName].compactMap { $0 }.joined(separator: " ・ "))
                .font(DSFont.caption)
                .foregroundStyle(DS.Gray.g400)
            if let date = item.eventDate {
                Text(DateFormatting.formatDateShort(date))
                    .font(DSFont.caption)
                    .foregroundStyle(DS.Gray.g400)
            }
        }
    }

    private func repCell(_ item: SharedBoardItem) -> some View {
        // 内部 UUID も会員番号も来ない。**サーバーが返した表示名だけ**を出す（P6）
        HStack(spacing: 4) {
            ColorDot(item.repColor)
            Text(item.repName).font(DSFont.caption)
        }
    }

    @ViewBuilder
    private func companionCell(_ item: SharedBoardItem) -> some View {
        Text(item.companions.isEmpty ? "—" : item.companions.joined(separator: "、"))
            .font(DSFont.caption)
            .foregroundStyle(DS.Gray.g900)
    }

    @ViewBuilder
    private func statusCell(_ item: SharedBoardItem) -> some View {
        if store.isEditable(item) {
            // 状況は 5 値から選ばせる（未知値を送れる経路を作らない）
            Menu {
                ForEach(ApplicationStatus.allCases, id: \.self) { status in
                    Button(status.label) {
                        Task { await store.setStatus(status, for: item) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    statusStamp(item.status)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Gray.g500)
                }
            }
            .disabled(store.isSaving(item))
        } else {
            // read リンク / `editable: false` は**タップできる要素を置かない**（AC-SB-08-M / 09-M）
            statusStamp(item.status)
        }
    }

    private func statusStamp(_ status: ApplicationStatus) -> some View {
        Text(status.label)
            .font(DSFont.captionBold)
            .foregroundStyle(stampColor(status))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stampBG(status))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func seatCell(_ item: SharedBoardItem) -> some View {
        if store.isEditable(item) {
            if editingSeatID == item.id {
                TextField("座席", text: $draftSeat)
                    .font(DSFont.caption)
                    .submitLabel(.done)
                    .onSubmit {
                        let value = draftSeat
                        editingSeatID = nil
                        // **空文字を `null` に丸めない**（P5）。空欄は空文字のまま送る
                        Task { await store.saveSeat(value, for: item) }
                    }
            } else {
                Button(seatLabel(item)) {
                    draftSeat = item.seat ?? ""
                    editingSeatID = item.id
                }
                .font(DSFont.caption)
                .foregroundStyle(DS.Gray.g900)
                .underline()
                .disabled(store.isSaving(item))
            }
        } else {
            Text(seatLabel(item)).font(DSFont.caption).foregroundStyle(DS.Gray.g900)
        }
    }

    /// `null` と空文字を見た目でも区別する（P5）。
    private func seatLabel(_ item: SharedBoardItem) -> String {
        guard let seat = item.seat else { return "未登録" }
        return seat.isEmpty ? "（空欄）" : seat
    }

    // MARK: - 表の体裁（`ApplicationListView` のツアー表と同じ寸法）

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

/// ディープリンク（`meigicho://share/<token>`）から**モーダルで**開くときの入れ物。
/// アプリ本体のタブ・ナビゲーションとは独立している（受け取り側は未ログインの前提）。
public struct SharedBoardScreen: View {
    private let token: String
    private let onClose: () -> Void

    public init(token: String, onClose: @escaping () -> Void) {
        self.token = token
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            SharedBoardView(token: token)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("閉じる", action: onClose)
                    }
                }
        }
    }
}

#Preview("共有ボード（閲覧のみ）") {
    NavigationStack {
        SharedBoardView(token: "preview-token")
    }
    .environment(SharedBoardStore())
    .environment(\.themeStore, ThemeStore())
}
