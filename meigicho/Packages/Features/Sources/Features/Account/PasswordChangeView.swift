import SwiftUI
import DesignSystem
import Domain

/// パスワード変更（`POST /v1/auth/password`・**Bearer 必須**）。
///
/// - 成功時、サーバーはその user の refresh token を**全件失効**させ新しいペアを返す。
///   `AuthStore.changePassword` が Keychain を上書きするので、**このまま操作を続けられる**（A5 / AC-EM-08-M）。
///   他端末は次の refresh でログイン画面に戻る（AC-EM-09-M）
/// - `auth_providers` に `"email"` が無いアカウントでは `AccountView` がこの画面への導線を出さない
///   （叩くと `FORBIDDEN` 403 — AC-EM-10-M）
struct PasswordChangeView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.themeStore) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    FormCard {
                        FormRow("現在のパスワード") {
                            SecureField("現在のパスワード", text: $currentPassword)
                                .font(DSFont.body)
                                .textContentType(.password)
                        }
                        FormRow("新しいパスワード") {
                            SecureField("8文字以上", text: $newPassword)
                                .font(DSFont.body)
                                .textContentType(.newPassword)
                        }
                        FormRow("新しいパスワード（確認）") {
                            SecureField("もう一度入力", text: $confirmPassword)
                                .font(DSFont.body)
                                .textContentType(.newPassword)
                        }
                    }

                    if let errorMessage {
                        FormHint(errorMessage, isError: true)
                    } else {
                        // **サーバーと同じ制約だけを書く**（IOS-4）
                        FormHint("パスワードは \(EmailCredentialRule.passwordMinLength)〜\(EmailCredentialRule.passwordMaxLength) 文字で設定できます。")
                    }

                    FormHint("変更すると、他の端末では再ログインが必要になります。")

                    PrimaryButton("パスワードを変更") {
                        Task { await submit() }
                    }
                    .disabled(auth.isBusy)
                    .padding(.top, 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(theme.bgApp)
            .navigationTitle("パスワードの変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func submit() async {
        errorMessage = nil
        guard newPassword == confirmPassword else {
            errorMessage = "確認用のパスワードが一致しません"
            return
        }
        do {
            try await auth.changePassword(current: currentPassword, new: newPassword)
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
            dismiss()
        } catch {
            errorMessage = AuthErrorText.message(for: error, context: .changePassword)
        }
    }
}

#Preview {
    PasswordChangeView()
        .environment(AuthStore())
        .environment(\.themeStore, ThemeStore())
}
