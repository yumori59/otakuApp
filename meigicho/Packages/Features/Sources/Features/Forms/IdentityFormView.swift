import SwiftUI
import DesignSystem
import Domain
import Core

/// 名義フォーム（追加・編集で共用）。
///
/// `.create` は追加フロー（TE-4 でリファクタ抽出・振る舞い不変）。
/// `.edit` は編集フロー（TE-6）。差分計算は `IdentityEditPlanner`（Domain・純粋関数）に委ね、
/// このビューは入力値の保持と `IdentityStore.updateIdentity` への配線のみを持つ。
enum IdentityFormMode {
    case create
    case edit(Identity)

    var isEdit: Bool {
        if case .edit = self { return true }
        return false
    }
}

struct IdentityFormView: View {
    let mode: IdentityFormMode

    @Environment(\.dismiss) private var dismiss
    @Environment(IdentityStore.self) private var identityStore
    @Environment(\.themeStore) private var theme

    /// create でのみ発火する（D-8）。edit の保存では呼ばれない
    var onSaved: (UUID) -> Void = { _ in }

    @State private var name = ""
    @State private var relation: Relation = .self
    /// 入会日を設定するかどうか。`.edit` でのみユーザーが操作できる（FR-IE-5 / AC-IE-05）。
    /// `.create` は従来どおり常に true（未設定へ戻す UI は出さない = NFR-1・追加フローの振る舞い不変）
    @State private var hasJoinedOn = true
    @State private var joinedOn = Date()
    @State private var color = Color(hexString: AvatarColors.defaultColor(index: 0))
    @State private var note = ""
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 編集の保存に失敗したらシートは閉じず、理由をここに出す（D-5・オフライン時など）
                if let error = identityStore.actionError {
                    ErrorBar(error.userMessage).padding(.bottom, 12)
                }
                FormSectionLabel("基本情報")
                FormCard {
                    FormRow("氏名・呼び方") {
                        FormTextField("例）鈴木 花子 / 友人C", text: $name)
                    }
                    FormRow("関係性") {
                        Picker("関係性", selection: $relation) {
                            ForEach(Relation.allCases, id: \.self) { r in
                                Text(r.label).tag(r)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    FormRow("入会日（この名義の運用を始めた日）") {
                        if mode.isEdit {
                            HStack {
                                Toggle("入会日を設定する", isOn: $hasJoinedOn)
                                    .font(DSFont.body)
                                if hasJoinedOn {
                                    Spacer()
                                    DatePicker("", selection: $joinedOn, displayedComponents: .date)
                                        .labelsHidden()
                                }
                            }
                        } else {
                            DatePicker("", selection: $joinedOn, displayedComponents: .date)
                                .labelsHidden()
                        }
                    }
                    FormRow("名義カラー（一覧・ツアー表での色分けに使用）") {
                        HStack {
                            ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                            Text("タップして色を選択")
                                .font(DSFont.caption)
                                .foregroundStyle(DS.Gray.g400)
                        }
                    }
                    FormRow("メモ") {
                        TextField("連絡手段や注意点など", text: $note, axis: .vertical)
                            .font(DSFont.body)
                            .lineLimit(3...6)
                    }
                }
                if !mode.isEdit {
                    FormHint("保存すると、続けてファンクラブ会員情報を登録する画面に進みます。")
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle(mode.isEdit ? "名義を編集" : "名義を追加")
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
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { populateInitialValues() }
    }

    /// `.create` は「今日」「配色順の既定カラー」を代入する（従来どおり）。
    /// `.edit` は**現在値**を代入する。`joinedOn` が未設定の名義を開いたときは `hasJoinedOn = false` にし、
    /// ユーザーが日付に触れない限り `.set(today)` として送られないようにする（D-8 / AC-IE-04）。
    ///
    /// `actionError` は `IdentityStore` 全体で共有される 1 本（カラー変更・備考編集・共有スイッチ・
    /// 他の名義/会員情報の編集失敗でも立つ）なので、モードによらずフォームを開いた時点でクリアする。
    /// クリアしないと前の画面の失敗が「追加」フォームの `ErrorBar` に残って誤表示される。
    private func populateInitialValues() {
        identityStore.actionError = nil
        switch mode {
        case .create:
            hasJoinedOn = true
            joinedOn = identityStore.today
            color = Color(hexString: AvatarColors.defaultColor(index: identityStore.identities.count))
        case .edit(let identity):
            name = identity.displayName
            relation = identity.relation
            hasJoinedOn = identity.joinedOn != nil
            joinedOn = identity.joinedOn ?? identityStore.today
            color = Color(hexString: identity.colorHex)
            note = identity.note
        }
    }

    private func save() {
        switch mode {
        case .create:
            saveCreate()
        case .edit(let identity):
            saveEdit(identity)
        }
    }

    private func saveCreate() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let identity = identityStore.addIdentity(
            displayName: trimmed,
            relation: relation,
            colorHex: color.hexString,
            joinedOn: joinedOn,
            note: note.trimmingCharacters(in: .whitespaces)
        )
        dismiss()
        onSaved(identity.id)
    }

    /// D-5: 楽観更新はしない。保存中はスピナー、成功したら dismiss、失敗はフォームを開いたままエラーバー
    private func saveEdit(_ identity: Identity) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let input = IdentityEditFormInput(
            displayName: trimmed,
            relation: relation,
            joinedOn: hasJoinedOn ? joinedOn : nil,
            colorHex: color.hexString,
            note: note.trimmingCharacters(in: .whitespaces)
        )
        isSaving = true
        Task {
            let updated = await identityStore.updateIdentity(id: identity.id, input: input)
            isSaving = false
            if updated != nil { dismiss() }
        }
    }
}
