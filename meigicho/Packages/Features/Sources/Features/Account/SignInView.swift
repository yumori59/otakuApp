import SwiftUI
import AuthenticationServices
import DesignSystem
import Domain

/// ログイン画面（`questions-requirements.md` Q5）。
///
/// **Apple / Google / メール+パスワードの 3 方式**（`contract-mapping.md` §4.1）。
public struct SignInView: View {
    /// メール欄のモード。`register` だけ **201** で新規作成される（A3）
    enum EmailMode {
        case signIn
        case register

        var primaryTitle: String {
            switch self {
            case .signIn: "メールアドレスでログイン"
            case .register: "メールアドレスで新規登録"
            }
        }

        var switchTitle: String {
            switch self {
            case .signIn: "アカウントをお持ちでない方は新規登録"
            case .register: "すでにアカウントをお持ちの方はログイン"
            }
        }
    }

    @Environment(AuthStore.self) private var auth
    @Environment(\.themeStore) private var theme

    @State private var mode: EmailMode = .signIn
    @State private var email = ""
    @State private var password = ""
    /// メールフォーム専用のエラー。復帰失敗の `ErrorBar` とは別に出す（タップで restore させない）
    @State private var formMessage: String?
    @State private var isResetPresented = false

    /// 未ログインで書き込み操作が要求されたときに出す理由（Q5）。
    /// nil なら通常のログイン画面
    private let reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let reason {
                    BigTitle("ログインが必要です", subtitle: reason)
                } else {
                    BigTitle("ログイン", subtitle: "続けるにはログインしてください")
                }

                if let message = auth.errorMessage {
                    // 通信できずに復帰できなかった場合はタップで再試行できる（アラートは出さない）
                    ErrorBar(message) {
                        Task { await auth.retryRestore() }
                    }
                    .padding(.bottom, 12)
                }

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                    // **設定した文字列をそのまま BE に送る**（sha256 しない — Q4 / A2）
                    request.nonce = auth.beginAppleSignIn()
                } onCompletion: { result in
                    handleAppleResult(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                .padding(.bottom, 12)
                .disabled(auth.isBusy)

                GoogleSignInButton("Googleでログイン") {
                    Task { await auth.signInWithGoogle() }
                }
                .disabled(auth.isBusy)

                LoginDivider()

                emailSection

                if auth.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("ログインしています…")
                            .font(DSFont.caption)
                            .foregroundStyle(DS.Gray.g600)
                    }
                    .padding(.top, 16)
                }

                FormHint("ログインすると、名義や申込の内容がアカウントに保存され、機種変更後も引き継げます。")
                    .padding(.top, 16)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bgApp)
        .sheet(isPresented: $isResetPresented) {
            PasswordResetView(initialEmail: email)
        }
    }

    // MARK: - メール + パスワード

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormCard {
                FormRow("メールアドレス") {
                    TextField("例）fan@example.com", text: $email)
                        .font(DSFont.body)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }
                FormRow("パスワード") {
                    SecureField(mode == .register ? "8文字以上" : "パスワード", text: $password)
                        .font(DSFont.body)
                        // 新規登録では自動生成パスワードを提案させる
                        .textContentType(mode == .register ? .newPassword : .password)
                }
            }

            if let formMessage {
                FormHint(formMessage, isError: true)
            } else if mode == .register {
                // **サーバーと同じ制約だけを書く**（大文字必須などを足さない — IOS-4）
                FormHint("パスワードは \(EmailCredentialRule.passwordMinLength)〜\(EmailCredentialRule.passwordMaxLength) 文字で設定できます。")
            }

            PrimaryButton(mode.primaryTitle) {
                Task { await submit() }
            }
            .disabled(auth.isBusy)
            .padding(.top, 12)

            HStack {
                Button(mode.switchTitle) {
                    mode = mode == .signIn ? .register : .signIn
                    formMessage = nil
                }
                .font(DSFont.caption)
                .foregroundStyle(theme.primary)

                Spacer()

                Button("パスワードを忘れた方") {
                    formMessage = nil
                    isResetPresented = true
                }
                .font(DSFont.caption)
                .foregroundStyle(theme.primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
        }
    }

    private func submit() async {
        formMessage = nil
        do {
            switch mode {
            case .signIn:
                try await auth.signInWithEmail(email: email, password: password)
            case .register:
                try await auth.registerWithEmail(email: email, password: password)
            }
            password = ""
        } catch {
            formMessage = AuthErrorText.message(for: error, context: mode == .signIn ? .signIn : .register)
        }
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                auth.failAppleSignIn()
                return
            }
            Task { await auth.completeAppleSignIn(identityToken: identityToken) }
        case .failure(let error):
            // ユーザーキャンセルはエラーにしない
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                return
            }
            auth.failAppleSignIn()
        }
    }
}

// MARK: - エラー文言

/// メール系エラーの文言。
///
/// **同じ `code` でも文脈で意味が変わる**ものだけをここで出し分け、
/// それ以外は `AppError.userMessage`（`contract-mapping.md` §2.3 の既定文言）に委ねる。
enum AuthErrorText {
    enum Context {
        /// ログイン: 401 は未登録 / パスワード誤り / パスワード未設定を**区別しない**（A7）
        case signIn
        case register
        /// パスワード変更: 401 は「現在のパスワードが違う」/ 403 は「パスワード未設定」
        case changePassword
        /// リセット: 401 は誤コード / 期限切れ / 使用済み / 試行超過を**区別しない**
        case resetPassword
        /// アカウント削除: `api-contract-delta.md`（account-deletion）§3.3 の文言表
        case deleteAccount
    }

    static func message(for error: Error, context: Context) -> String {
        if let inputError = error as? EmailCredentialError {
            return inputError.userMessage
        }
        guard let appError = error as? AppError else {
            return AppError.unknown(code: "UNEXPECTED", message: nil).userMessage
        }
        switch (appError, context) {
        case (.credentialsInvalid, .changePassword):
            return "現在のパスワードが違います"
        case (.forbidden, .changePassword):
            return "このアカウントにはパスワードが設定されていません"
        case (.validation, .register), (.validation, .resetPassword):
            return "パスワードは \(EmailCredentialRule.passwordMinLength)〜\(EmailCredentialRule.passwordMaxLength) 文字で入力してください"
        case (.credentialsInvalid, .deleteAccount):
            return "パスワードが違います"
        case (.validation, .deleteAccount):
            // プロフィール未取得のまま password 無しで送ると BE が 400 を返す（review.md 中-4）
            return "パスワードの入力が必要です。画面を開き直してください"
        case (.notFound, .deleteAccount):
            return "このアカウントは既に削除されています"
        case (.offline, .deleteAccount), (.timeout, .deleteAccount), (.transport, .deleteAccount), (.server, .deleteAccount):
            return "削除できませんでした。通信状況を確認してもう一度お試しください"
        default:
            return appError.userMessage
        }
    }
}

#Preview("通常") {
    SignInView()
        .environment(AuthStore.preview(state: .signedOut))
        .environment(\.themeStore, ThemeStore())
}

#Preview("書き込み操作からの誘導") {
    SignInView(reason: SignInPrompt.addIdentity)
        .environment(AuthStore.preview(state: .signedOut))
        .environment(\.themeStore, ThemeStore())
}
