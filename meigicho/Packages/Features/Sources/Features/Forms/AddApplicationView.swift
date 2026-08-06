import SwiftUI
import DesignSystem
import Domain
import Core

struct AddApplicationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(\.themeStore) private var theme

    @State private var eventName = ""
    @State private var tourName = ""
    @State private var artistName = ""
    @State private var venueName = ""
    @State private var eventOn = Date()
    @State private var repIdentityID: UUID?
    @State private var companionSelections: [UUID?] = [nil, nil, nil]
    @State private var companionNames: [String] = ["", "", ""]
    @State private var appliedOn = Date()
    @State private var resultOn = Date()
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
                    }
                    FormRow("会場") {
                        FormTextField("例）マリンメッセ福岡", text: $venueName)
                    }
                    FormRow("公演日") {
                        DatePicker("", selection: $eventOn, displayedComponents: .date).labelsHidden()
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
                        DatePicker("", selection: $appliedOn, displayedComponents: .date).labelsHidden()
                    }
                    FormRow("当落発表日") {
                        DatePicker("", selection: $resultOn, displayedComponents: .date).labelsHidden()
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
        .navigationTitle("申込を追加")
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
        .onAppear {
            let today = applicationStore.today
            eventOn = today
            appliedOn = today
            resultOn = today
            repIdentityID = identityStore.identities.first?.id
            applicationStore.clearWriteError()
        }
    }

    private var filteredTours: [String] {
        let q = tourName.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return applicationStore.existingTourNames.filter {
            $0.localizedCaseInsensitiveContains(q) && $0.caseInsensitiveCompare(q) != .orderedSame
        }
    }

    private func save() {
        let event = eventName.trimmingCharacters(in: .whitespaces)
        guard let repID = repIdentityID, !event.isEmpty else { return }
        let tour = tourName.trimmingCharacters(in: .whitespaces).isEmpty ? event : tourName.trimmingCharacters(in: .whitespaces)

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
}
