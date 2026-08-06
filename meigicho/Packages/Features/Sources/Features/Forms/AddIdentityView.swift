import SwiftUI
import DesignSystem
import Domain
import Core

struct AddIdentityView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(IdentityStore.self) private var identityStore
    @Environment(\.themeStore) private var theme

    let onSaved: (UUID) -> Void

    @State private var name = ""
    @State private var relation: Relation = .self
    @State private var joinedOn = Date()
    @State private var color = Color(hexString: AvatarColors.defaultColor(index: 0))
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
                        DatePicker("", selection: $joinedOn, displayedComponents: .date)
                            .labelsHidden()
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
                FormHint("保存すると、続けてファンクラブ会員情報を登録する画面に進みます。")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle("名義を追加")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .font(DSFont.bodyBold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            joinedOn = identityStore.today
            color = Color(hexString: AvatarColors.defaultColor(index: identityStore.identities.count))
        }
    }

    private func save() {
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
}
