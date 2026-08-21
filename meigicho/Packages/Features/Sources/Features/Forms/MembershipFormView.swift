import SwiftUI
import DesignSystem
import Domain
import Core

/// 会員情報フォーム（追加・編集で共用）。
///
/// `.create` は追加フロー（TE-5 でリファクタ抽出・振る舞い不変）。
/// `.edit` は編集フロー（TE-6）。差分計算は `MembershipEditPlanner`（Domain・純粋関数）に委ね、
/// このビューは入力値の保持と `IdentityStore.updateMembership` への配線のみを持つ。
enum MembershipFormMode {
    case create(identityID: UUID)
    case edit(Membership)

    var isEdit: Bool {
        if case .edit = self { return true }
        return false
    }
}

struct MembershipFormView: View {
    /// BE の `@MaxLength(64)`（`create-membership.dto.ts` / `update-membership.dto.ts`）と揃える
    private static let memberNoMaxLength = 64

    let mode: MembershipFormMode

    @Environment(\.dismiss) private var dismiss
    @Environment(IdentityStore.self) private var identityStore
    @Environment(\.themeStore) private var theme
    @Environment(\.notificationBridge) private var notifications

    @State private var fcName = ""
    /// 会員番号は全桁を平文で保持する（2026-08-20 ユーザー判断で暗号化・下4桁表示を撤回）。1〜64 文字・文字種は制限しない
    @State private var memberNo = ""
    /// 更新日は未設定のまま保存できる（AC-ID-09-M）
    @State private var hasRenewalOn = false
    @State private var renewalOn = Date()
    @State private var feeText = ""
    @State private var showNotificationPermission = false
    @State private var isSaving = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @AppStorage("notificationPermissionDeferred") private var notificationPermissionDeferred = false

    private var identityID: UUID {
        switch mode {
        case .create(let identityID):
            return identityID
        case .edit(let membership):
            return membership.identityID
        }
    }

    private var identityName: String {
        identityStore.identity(for: identityID)?.displayName ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 編集の保存に失敗したらシートは閉じず、理由をここに出す（D-5・オフライン時など）
                if let error = identityStore.actionError {
                    ErrorBar(error.userMessage).padding(.bottom, 12)
                }
                FormSectionLabel("\(identityName) の会員情報")
                FormCard {
                    FormRow("ファンクラブ / アーティスト名") {
                        FormTextField("例）STELLARIS OFFICIAL FAN CLUB", text: $fcName)
                    }
                    FormRow("会員番号（任意）") {
                        FormTextField("例）STL-04821", text: $memberNo)
                            .onChange(of: memberNo) { old, new in
                                // 文字種は制限しない。上限64文字を超える入力は受け付けない（BE の @MaxLength(64) と揃える）。
                                // FR-MN-4: 切り詰めではなく打ち止め。prefix で削ると末尾が黙って欠落するため、
                                // 変更前の値へ戻して「それ以上入力できない」挙動にする
                                if new.count > Self.memberNoMaxLength {
                                    memberNo = old
                                }
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
                if mode.isEdit {
                    deleteButton()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle(mode.isEdit ? "会員情報を編集" : "会員情報を追加")
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
                        .disabled(fcName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear { populateInitialValues() }
        .sheet(isPresented: $showNotificationPermission, onDismiss: { dismiss() }) {
            NotificationPermissionSheet(
                renewalDate: renewalOn,
                onAccept: { await notifications.requestAndSchedule() },
                onDefer: { notificationPermissionDeferred = true }
            )
        }
        .confirmationDialog(
            "この会員情報を削除しますか？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("削除する", role: .destructive) {
                Task { await deleteMembership() }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("この操作は取り消せません。名義や申込の記録は残ります。")
        }
    }

    private func deleteButton() -> some View {
        Button(role: .destructive) {
            showDeleteConfirmation = true
        } label: {
            Text("この会員情報を削除")
                .font(DSFont.bodyBold)
                .foregroundStyle(DS.error)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .disabled(isDeleting || isSaving)
        .padding(.top, 8)
    }

    /// 削除実行。成功したら**先にシートを閉じてから**通知を再スケジュールする。
    /// `identityStore.memberships` から該当行が消えると `SheetContentView` の body 再評価で
    /// このビューが `EmptyStateView` に差し替わるため、`dismiss()` を長い `await` の後に回すと
    /// 既にビュー階層から外れた `DismissAction` を呼ぶことになり、シートが閉じなくなる
    /// （`IdentityDetailView.deleteIdentity` / `ApplicationDetailView` と同じ順序に揃える）。
    /// 失敗時はシートを閉じず `actionError` の表示に任せる（`identityStore.deleteMembership` が設定する）。
    private func deleteMembership() async {
        guard case .edit(let membership) = mode else { return }
        isDeleting = true
        let ok = await identityStore.deleteMembership(membership.id)
        isDeleting = false
        guard ok else { return }
        dismiss()
        await notifications.rescheduleIfAuthorized()
    }

    /// `.create` は「今日」を仮の更新日として代入する（従来どおり）。
    /// `.edit` は**現在値**を代入する。**edit では初回の通知許可シートを出さない**（D-8）
    ///
    /// `actionError` は `IdentityStore` 全体で共有される 1 本（カラー変更・備考編集・共有スイッチ・
    /// 他の名義/会員情報の編集失敗でも立つ）なので、モードによらずフォームを開いた時点でクリアする。
    /// クリアしないと前の画面の失敗が「追加」フォームの `ErrorBar` に残って誤表示される。
    private func populateInitialValues() {
        identityStore.actionError = nil
        switch mode {
        case .create:
            renewalOn = identityStore.today
        case .edit(let membership):
            fcName = membership.fanClubNameRaw
            memberNo = membership.memberNo ?? ""
            hasRenewalOn = membership.renewalOn != nil
            renewalOn = membership.renewalOn ?? identityStore.today
            feeText = membership.feeYen.map(String.init) ?? ""
        }
    }

    private func save() {
        switch mode {
        case .create:
            saveCreate()
        case .edit(let membership):
            saveEdit(membership)
        }
    }

    private func saveCreate() {
        let fc = fcName.trimmingCharacters(in: .whitespaces)
        guard !fc.isEmpty else { return }
        let trimmedMemberNo = memberNo.trimmingCharacters(in: .whitespaces)
        let isFirstMembershipEver = identityStore.memberships.isEmpty
        identityStore.addMembership(
            to: identityID,
            fanClubNameRaw: fc,
            memberNo: trimmedMemberNo.isEmpty ? nil : trimmedMemberNo,
            renewalOn: hasRenewalOn ? renewalOn : nil,
            feeYen: Int(feeText)
        )
        if hasRenewalOn, isFirstMembershipEver, !notificationPermissionDeferred {
            showNotificationPermission = true
        } else {
            dismiss()
        }
    }

    /// D-5: 楽観更新はしない。保存中はスピナー、成功したら dismiss、失敗はフォームを開いたままエラーバー。
    /// 更新日が変わりうるため、成功後は許可済みなら通知を再スケジュールする（AC-IE-17）
    private func saveEdit(_ membership: Membership) {
        let fc = fcName.trimmingCharacters(in: .whitespaces)
        guard !fc.isEmpty else { return }
        let trimmedMemberNo = memberNo.trimmingCharacters(in: .whitespaces)
        let input = MembershipEditFormInput(
            fanClubNameRaw: fc,
            memberNoRaw: trimmedMemberNo,
            renewalOn: hasRenewalOn ? renewalOn : nil,
            feeYen: Int(feeText)
        )
        isSaving = true
        Task {
            let updated = await identityStore.updateMembership(id: membership.id, input: input)
            isSaving = false
            guard updated != nil else { return }
            await notifications.rescheduleIfAuthorized()
            dismiss()
        }
    }
}
