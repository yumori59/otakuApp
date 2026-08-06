import SwiftUI
import DesignSystem
import Domain

/// パスワードリセット（`api-contract-delta.md` §1 の `password/reset-request` → `password/reset`）。
///
/// 2 段階:
/// 1. `POST /v1/auth/password/reset-request` — **202 / ボディ無し**。登録の有無に関わらず同じ応答なので
///    「送信しました」と断定せず「**登録されていれば**送信しました」と書く（A4 / AC-EM-11-M）
/// 2. `POST /v1/auth/password/reset` — 成功すると**そのままログイン状態になる**（A6 / AC-EM-12-M）
///
/// 429（`.rateLimited`）は文言を出すだけで**自動リトライしない**（A11 / AC-EM-14-M）。
struct PasswordResetView: View {
    enum Step {
        case requestCode
        case enterCode
    }

    @Environment(AuthStore.self) private var auth
    @Environment(\.themeStore) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .requestCode
    @State private var email: String
    @State private var code = ""
    @State private var newPassword = ""
    @State private var errorMessage: String?
    /// 「登録されていれば送信しました」。**存在を断定しない**
    @State private var notice: String?

    init(initialEmail: String = "") {
        _email = State(initialValue: initialEmail)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch step {
                    case .requestCode:
                        requestSection
                    case .enterCode:
                        resetSection
                    }

                    if let errorMessage {
                        FormHint(errorMessage, isError: true)
                    } else if let notice {
                        FormHint(notice)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(theme.bgApp)
            .navigationTitle("パスワードの再設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    // MARK: - 1. コードの送信を依頼する

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormHint("登録済みのメールアドレスに、確認コードをお送りします。")

            FormCard {
                FormRow("メールアドレス") {
                    TextField("例）fan@example.com", text: $email)
                        .font(DSFont.body)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }
            }
            .padding(.top, 8)

            PrimaryButton("確認コードを送る") {
                Task { await requestCode() }
            }
            .disabled(auth.isBusy)
            .padding(.top, 12)

            Button("コードを受け取り済みの方はこちら") {
                errorMessage = nil
                step = .enterCode
            }
            .font(DSFont.caption)
            .foregroundStyle(theme.primary)
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }

    private func requestCode() async {
        errorMessage = nil
        notice = nil
        do {
            try await auth.requestPasswordReset(email: email)
            // **登録の有無は分からない**（アカウント列挙防止で常に 202）
            notice = "入力したメールアドレスが登録されていれば、確認コードを送信しました。"
            step = .enterCode
        } catch {
            errorMessage = AuthErrorText.message(for: error, context: .resetPassword)
        }
    }

    // MARK: - 2. コードと新しいパスワードを入れる

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormHint("メールに記載された \(EmailCredentialRule.resetCodeLength) 桁の確認コードと、新しいパスワードを入力してください。")

            FormCard {
                FormRow("メールアドレス") {
                    TextField("例）fan@example.com", text: $email)
                        .font(DSFont.body)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }
                FormRow("確認コード（\(EmailCredentialRule.resetCodeLength)桁の数字）") {
                    TextField("12345678", text: $code)
                        .font(DSFont.body.monospaced())
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .onChange(of: code) { _, value in
                            // `^\d{8}$`。数字以外と 8 桁超は入力段階で落とす（A8）
                            let digits = value.filter { $0.isASCII && $0.isNumber }
                            code = String(digits.prefix(EmailCredentialRule.resetCodeLength))
                        }
                }
                FormRow("新しいパスワード") {
                    SecureField("8文字以上", text: $newPassword)
                        .font(DSFont.body)
                        .textContentType(.newPassword)
                }
            }
            .padding(.top, 8)

            PrimaryButton("パスワードを再設定") {
                Task { await resetPassword() }
            }
            .disabled(auth.isBusy)
            .padding(.top, 12)

            Button("コードを再送する") {
                errorMessage = nil
                notice = nil
                step = .requestCode
            }
            .font(DSFont.caption)
            .foregroundStyle(theme.primary)
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }

    private func resetPassword() async {
        errorMessage = nil
        do {
            try await auth.resetPassword(email: email, code: code, newPassword: newPassword)
            // 成功時はサーバーが新しいトークンペアを返し、`AuthStore` が採用済み（A6）。
            // ログイン状態のまま画面を閉じる
            newPassword = ""
            code = ""
            dismiss()
        } catch {
            errorMessage = AuthErrorText.message(for: error, context: .resetPassword)
        }
    }
}

#Preview {
    PasswordResetView()
        .environment(AuthStore())
        .environment(\.themeStore, ThemeStore())
}
