import SwiftUI
import DesignSystem
import Domain
import Core

/// 申込フォーム（追加・編集で共用）。
///
/// `.create` は追加フロー（T4 でリファクタ抽出・振る舞い不変）。
/// `.edit` は編集フロー（T5）。差分計算は `ApplicationEditPlanner`（Domain・純粋関数）に委ね、
/// このビューは入力値の保持と `ApplicationStore.updateApplication` への配線のみを持つ。
enum ApplicationFormMode {
    case create
    case edit(ApplicationEntry)

    var isEdit: Bool {
        if case .edit = self { return true }
        return false
    }
}

struct ApplicationFormView: View {
    let mode: ApplicationFormMode

    @Environment(\.dismiss) private var dismiss
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(\.themeStore) private var theme

    @State private var eventName = ""
    @State private var tourName = ""
    @State private var artistName = ""
    @State private var venueName = ""
    // 修正1（レビュー中4件）: nil は「編集モードでユーザーが未だ触れていない」ことを表す。
    // DatePicker には `eventOnBinding` 等の計算 Binding 経由でしか触れさせないため、
    // ユーザーが一度もタップしなければ nil のまま保存される（= makePlan が無変更と判定する）。
    // 作成モードは populateInitialValues で必ず today を代入するのでこの区別は生じない。
    @State private var eventOn: Date?
    @State private var repIdentityID: UUID?
    @State private var companionSelections: [UUID?] = [nil, nil, nil]
    @State private var companionNames: [String] = ["", "", ""]
    @State private var appliedOn: Date?
    @State private var resultOn: Date?
    @State private var status: ApplicationStatus = .applied
    @State private var seat = ""
    @State private var note = ""
    @State private var showTourSuggestions = false
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 保存に失敗したらフォームは閉じず、理由をここに出す（オフライン時など）
                if let error = applicationStore.writeError {
                    ErrorBar(error.userMessage).padding(.bottom, 12)
                }
                FormSectionLabel("公演情報")
                FormCard {
                    FormRow("公演名") {
                        FormTextField("例）STELLARIS ARENA TOUR 2026 -福岡公演-", text: $eventName)
                        // FR-AE-7/8: 公演名・会場・公演日の変更は他の申込にも波及する（波及先がある場合のみ表示）
                        if let count = editAffectedOtherApplicationsCount, count > 0 {
                            FormHint("この公演を参照する他 \(count) 件にも反映されます。")
                                .padding(.top, 6)
                        }
                    }
                    FormRow("ツアー名（同じツアーの公演をまとめて表で見る際に使用）") {
                        FormTextField("例）STELLARIS ARENA TOUR 2026", text: $tourName)
                        FormHint("空欄の場合は公演名がそのままツアー名として使われます。")
                            .padding(.top, 6)
                        if !filteredTours.isEmpty && !tourName.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(filteredTours, id: \.self) { tour in
                                    Button(tour) { tourName = tour }
                                        .font(DSFont.body)
                                        .foregroundStyle(theme.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                    }
                    FormRow("アーティスト / グループ") {
                        FormTextField("例）STELLARIS", text: $artistName)
                        // FR-AE-8: アーティスト名の変更は同じツアーの申込すべてに反映される
                        if mode.isEdit {
                            FormHint("同じツアーの申込すべてに反映されます。")
                                .padding(.top, 6)
                        }
                    }
                    FormRow("会場") {
                        FormTextField("例）マリンメッセ福岡", text: $venueName)
                    }
                    FormRow("公演日") {
                        DatePicker("", selection: eventOnBinding, displayedComponents: .date).labelsHidden()
                    }
                }

                FormSectionLabel("申込内容")
                FormCard {
                    FormRow("代表者（FC名義で申し込む人）") {
                        Picker("代表者", selection: Binding(
                            get: { repIdentityID ?? identityStore.identities.first?.id ?? UUID() },
                            set: { repIdentityID = $0 }
                        )) {
                            ForEach(identityStore.identities) { identity in
                                Text(identity.displayName).tag(identity.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    ForEach(0..<3, id: \.self) { n in
                        FormRow("同行者\(n + 1)（任意）") {
                            Picker("名義", selection: $companionSelections[n]) {
                                Text("指定しない").tag(UUID?.none)
                                ForEach(identityStore.identities) { identity in
                                    Text(identity.displayName).tag(Optional(identity.id))
                                }
                            }
                            .pickerStyle(.menu)
                            FormTextField("名義未登録の場合はここに氏名を入力", text: $companionNames[n])
                                .padding(.top, 8)
                        }
                    }
                    FormHint("同行者は最大3人まで追加できます。代表者と同じ人は選べません。")
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    FormRow("申込日") {
                        DatePicker("", selection: appliedOnBinding, displayedComponents: .date).labelsHidden()
                    }
                    FormRow("当落発表日") {
                        DatePicker("", selection: resultOnBinding, displayedComponents: .date).labelsHidden()
                    }
                    FormRow("ステータス") {
                        Picker("ステータス", selection: $status) {
                            ForEach([ApplicationStatus.draft, .applied, .won, .lost], id: \.self) { s in
                                Text(s.label).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        FormTextField("座席（例：アリーナ8列15番）", text: $seat)
                            .padding(.top, 9)
                    }
                    FormRow("メモ") {
                        TextField("任意", text: $note, axis: .vertical)
                            .font(DSFont.body)
                            .lineLimit(2...4)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle(mode.isEdit ? "申込を編集" : "申込を追加")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("保存") { save() }
                        .font(DSFont.bodyBold)
                        .disabled(eventName.trimmingCharacters(in: .whitespaces).isEmpty || repIdentityID == nil)
                }
            }
        }
        .onAppear { populateInitialValues() }
    }

    // MARK: - 初期値

    private func populateInitialValues() {
        switch mode {
        case .create:
            let today = applicationStore.today
            eventOn = today
            appliedOn = today
            resultOn = today
            repIdentityID = identityStore.identities.first?.id
            applicationStore.clearWriteError()
        case .edit(let entry):
            // FR-AE-12: 開いた時点で既に削除済み / 存在しない申込は編集できない
            guard let current = applicationStore.application(for: entry.id) else {
                applicationStore.writeError = .notFound
                dismiss()
                return
            }
            // 修正2（レビュー中4件）: tour/event が手元に無いまま空欄フォームを開かせない。
            // AC-AE-12 と同じ扱い（.notFound でシートを閉じる）。ApplicationStore.updateApplication も
            // tour/event の nil を .notFound で弾くため、ここで弾かないと入力を無駄にする（保存で必ず失敗する）。
            guard let tour = applicationStore.tour(for: current.tourID),
                  let event = applicationStore.event(for: current.eventID)
            else {
                applicationStore.writeError = .notFound
                dismiss()
                return
            }
            eventName = event.name
            tourName = tour.name
            artistName = tour.artistNameRaw
            venueName = event.venueNameRaw
            // 修正1: nil のまま保持する（DatePicker は触られない限り nil を維持する計算 Binding 経由でのみ表示）
            eventOn = event.eventDate
            repIdentityID = current.repIdentityID
            // FR-AE-5: 既存同行者との対応はインデックス（= position）
            let sortedCompanions = current.companions.sorted { $0.position < $1.position }
            for n in 0..<3 {
                if n < sortedCompanions.count {
                    let companion = sortedCompanions[n]
                    companionSelections[n] = companion.identityID
                    companionNames[n] = companion.identityID == nil ? companion.displayName : ""
                } else {
                    companionSelections[n] = nil
                    companionNames[n] = ""
                }
            }
            // 修正1: nil のまま保持する（触っていない場合は保存時も nil のまま送る）
            appliedOn = current.appliedOn
            resultOn = current.resultOn
            status = current.status
            seat = current.seatRaw
            note = current.note
            applicationStore.clearWriteError()
        }
    }

    /// 修正1: DatePicker には `?? applicationStore.today` で「今日」を仮表示するが、
    /// ユーザーが実際にピッカーを操作しない限り `set` は呼ばれないため、対応する `@State` は
    /// nil のまま保たれる（= 保存時に「無変更」として扱われる。`ApplicationEditPlanner.makePlan` 参照）。
    private var eventOnBinding: Binding<Date> {
        Binding(get: { eventOn ?? applicationStore.today }, set: { eventOn = $0 })
    }
    private var appliedOnBinding: Binding<Date> {
        Binding(get: { appliedOn ?? applicationStore.today }, set: { appliedOn = $0 })
    }
    private var resultOnBinding: Binding<Date> {
        Binding(get: { resultOn ?? applicationStore.today }, set: { resultOn = $0 })
    }

    private var filteredTours: [String] {
        let q = tourName.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return applicationStore.existingTourNames.filter {
            $0.localizedCaseInsensitiveContains(q) && $0.caseInsensitiveCompare(q) != .orderedSame
        }
    }

    // MARK: - 同行者入力の共通変換

    /// 同行者スロットの現在値。名義を選んでいれば名義の表示名を、そうでなければ自由入力の氏名を使う
    /// （`saveCreate` の同行者組み立てループと同じ規則: 代表者と同一名義が選ばれているスロットは
    /// 識別名義として使わず、自由入力欄 `companionNames[n]` にフォールバックする。AC-AE-06 の
    /// 「代表者と同じ人は選べません」というUIヒントと矛盾しないよう、作成/編集で解決規則を1本にする）
    private var companionInputs: [CompanionInput] {
        (0..<3).map { n in
            if let sel = companionSelections[n], sel != repIdentityID, let identity = identityStore.identity(for: sel) {
                return CompanionInput(identityID: sel, displayName: identity.displayName)
            }
            return CompanionInput(identityID: nil, displayName: companionNames[n])
        }
    }

    private var trimmedEventName: String { eventName.trimmingCharacters(in: .whitespaces) }
    private var trimmedTourName: String {
        let trimmed = tourName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? trimmedEventName : trimmed
    }

    private func editFormInput(repID: UUID) -> ApplicationEditFormInput {
        ApplicationEditFormInput(
            eventName: trimmedEventName,
            tourName: trimmedTourName,
            artistNameRaw: artistName.trimmingCharacters(in: .whitespaces),
            venueNameRaw: venueName.trimmingCharacters(in: .whitespaces),
            eventDate: eventOn,
            repIdentityID: repID,
            companions: companionInputs,
            appliedOn: appliedOn,
            resultOn: resultOn,
            status: status,
            seatRaw: seat,
            note: note
        )
    }

    /// FR-AE-7: 公演名 / 会場 / 公演日の変更が他の申込にも波及するか。編集モードでのみ意味を持つ。
    private var editAffectedOtherApplicationsCount: Int? {
        guard case .edit(let entry) = mode,
              let repID = repIdentityID,
              let tour = applicationStore.tour(for: entry.tourID),
              let event = applicationStore.event(for: entry.eventID)
        else { return nil }
        let plan = ApplicationEditPlanner.makePlan(
            current: entry,
            currentTour: tour,
            currentEvent: event,
            input: editFormInput(repID: repID)
        )
        // 修正4（レビュー中4件）: ツアー名だけの変更でも `updateScoped` は event.tourID を付け替え、
        // 同じ event_id を共有する他の申込ごと別ツアーへ移動する。event 側の変更に限定していると
        // ツアー名のみの変更で波及警告が出ない
        guard plan.eventDraft != nil || plan.tourDraft != nil else { return 0 }
        return applicationStore.coApplications(for: entry.eventID).filter { $0.id != entry.id }.count
    }

    private func save() {
        switch mode {
        case .create:
            saveCreate()
        case .edit(let entry):
            saveEdit(entry: entry)
        }
    }

    private func saveCreate() {
        let event = trimmedEventName
        guard let repID = repIdentityID, !event.isEmpty else { return }
        let tour = trimmedTourName

        var companions: [Companion] = []
        for n in 0..<3 {
            if let sel = companionSelections[n], sel != repID, !companions.contains(where: { $0.identityID == sel }) {
                if let identity = identityStore.identity(for: sel) {
                    companions.append(
                        Companion(identityID: sel, displayName: identity.displayName, position: companions.count)
                    )
                    continue
                }
            }
            let nameText = companionNames[n].trimmingCharacters(in: .whitespaces)
            if !nameText.isEmpty {
                companions.append(Companion(identityID: nil, displayName: nameText, position: companions.count))
            }
        }

        let draft = ApplicationDraft(
            tour: TourDraft(name: tour, artistNameRaw: artistName.trimmingCharacters(in: .whitespaces)),
            event: EventDraft(
                name: event,
                venueNameRaw: venueName.trimmingCharacters(in: .whitespaces),
                eventDate: eventOn
            ),
            repIdentityID: repID,
            // FR-AP-7: rep_membership_id は当面送らない
            repMembershipID: nil,
            appliedOn: appliedOn,
            resultOn: resultOn,
            status: status,
            seatRaw: seat.trimmingCharacters(in: .whitespaces),
            note: note.trimmingCharacters(in: .whitespaces),
            companions: companions
        )
        // 成功したときだけ閉じる。失敗したら入力を残したままエラーバーを出す
        isSaving = true
        Task {
            let created = await applicationStore.addApplication(draft)
            isSaving = false
            if created != nil { dismiss() }
        }
    }

    /// D-5: 楽観更新はしない。保存中はスピナー、成功したら dismiss、失敗はフォームを開いたままエラーバー
    private func saveEdit(entry: ApplicationEntry) {
        guard let repID = repIdentityID, !trimmedEventName.isEmpty else { return }
        let input = editFormInput(repID: repID)
        isSaving = true
        Task {
            let updated = await applicationStore.updateApplication(entry.id, input: input)
            isSaving = false
            if updated != nil { dismiss() }
        }
    }
}
