import SwiftUI
import DesignSystem
import Domain
import Core

struct AddMembershipView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(IdentityStore.self) private var identityStore
    @Environment(\.themeStore) private var theme
    @Environment(\.notificationBridge) private var notifications

    let identityID: UUID

    @State private var fcName = ""
    /// 会員番号は**下 4 桁だけ**保持する（`contract-mapping.md` §3.2 / C5）。1〜4 文字の英数のみ
    @State private var memberNoLast4 = ""
    /// 更新日は未設定のまま保存できる（AC-ID-09-M）
    @State private var hasRenewalOn = false
    @State private var renewalOn = Date()
    @State private var feeText = ""
    @State private var showNotificationPermission = false
    @AppStorage("notificationPermissionDeferred") private var notificationPermissionDeferred = false

    private var identityName: String {
        identityStore.identity(for: identityID)?.displayName ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FormSectionLabel("\(identityName) の会員情報")
                FormCard {
                    FormRow("ファンクラブ / アーティスト名") {
                        FormTextField("例）STELLARIS OFFICIAL FAN CLUB", text: $fcName)
                    }
                    FormRow("会員番号の下4桁（任意）") {
                        FormTextField("例）4821", text: $memberNoLast4)
                            .onChange(of: memberNoLast4) { _, new in
                                // 1〜4 文字の英数のみ（`contract-mapping.md` §4.4）
                                let filtered = new.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                                memberNoLast4 = String(filtered.prefix(4))
                            }
                    }
                    FormRow("更新日") {
                        HStack {
                            Toggle("更新日を設定する", isOn: $hasRenewalOn)
                                .font(DSFont.body)
                            if hasRenewalOn {
                                Spacer()
                                DatePicker("", selection: $renewalOn, displayedComponents: .date).labelsHidden()
                            }
                        }
                    }
                    FormRow("年会費（円）") {
                        FormTextField("4000", text: $feeText)
                            .keyboardType(.numberPad)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle("会員情報を追加")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .font(DSFont.bodyBold)
                    .disabled(fcName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            renewalOn = identityStore.today
        }
        .sheet(isPresented: $showNotificationPermission, onDismiss: { dismiss() }) {
            NotificationPermissionSheet(
                renewalDate: renewalOn,
                onAccept: { await notifications.requestAndSchedule() },
                onDefer: { notificationPermissionDeferred = true }
            )
        }
    }

    private func save() {
        let fc = fcName.trimmingCharacters(in: .whitespaces)
        guard !fc.isEmpty else { return }
        let last4 = memberNoLast4.trimmingCharacters(in: .whitespaces)
        let isFirstMembershipEver = identityStore.memberships.isEmpty
        identityStore.addMembership(
            to: identityID,
            fanClubNameRaw: fc,
            memberNoLast4: last4.isEmpty ? nil : last4,
            renewalOn: hasRenewalOn ? renewalOn : nil,
            feeYen: Int(feeText)
        )
        if hasRenewalOn, isFirstMembershipEver, !notificationPermissionDeferred {
            showNotificationPermission = true
        } else {
            dismiss()
        }
    }
}
