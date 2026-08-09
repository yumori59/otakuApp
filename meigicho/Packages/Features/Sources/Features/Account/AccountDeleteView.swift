import SwiftUI
import DesignSystem
import Domain

/// `DELETE /v1/me` の確認画面（`docs/plans/account-deletion/plan.md` §5.2）。
///
/// - 件数は出さない（Q5 = A）。復元できないことと削除対象の列挙のみ
/// - `profile.hasPasswordLogin` の有無で確認方法を出し分ける（パスワード入力 / 「削除」の typed confirmation）
/// - 成功時は `AuthStore.deleteAccount` の後始末（Keychain・セッション）に加えて、
///   画面側で各ストア・テーマを既定に戻す（`AccountLocalDataClearing`）
/// - `.notFound` は「既に削除済み」とみなし、同じくローカルクリアまで進める（`api-contract-delta.md` §3.3）
struct AccountDeleteView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(ProfileStore.self) private var profile
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(ShareLinkStore.self) private var shareLinkStore
    @Environment(AppSettingsStore.self) private var appSettings
    @Environment(\.themeStore) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmationText = ""
    @State private var errorMessage: String?
    /// Apple 再認可（システムシート）の進行中フラグ。`auth.isBusy` はまだ false なので連打を防げない
    @State private var isReauthorizing = false
    /// `NOT_FOUND`（既に削除済み）の告知。**OK を押してからローカルを消して閉じる**（`api-contract-delta.md` §3.3）
    @State private var alreadyDeletedMessage: String?
    /// Apple 再認可の実体。**`ASAuthorizationController` の delegate は weak** なので、
    /// コールバックが返るまで生存させる強参照をここに置く（コーディネーター自身も自己参照を持つ）
    @State private var appleReauthorization: AppleReauthorizationCoordinator?

    private static let confirmationPhrase = "削除"
    private static let subscriptionManagementURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    private var showsSubscriptionNotice: Bool {
        profile.entitlement?.plan == .plus || profile.entitlement?.inGracePeriod == true
    }

    private var isWorking: Bool { auth.isBusy || isReauthorizing }

    private var canExecute: Bool {
        guard !isWorking else { return false }
        if profile.hasPasswordLogin {
            return !password.isEmpty
        }
        return confirmationText == Self.confirmationPhrase
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BigTitle(
                        "アカウントを削除します",
                        subtitle: "削除すると次のデータがすべて削除され、復元はできません。"
                    )

                    deletionTargets
                        .padding(.bottom, 16)

                    if showsSubscriptionNotice {
                        subscriptionNotice
                            .padding(.bottom, 16)
                    }

                    if let errorMessage {
                        ErrorBar(errorMessage) { self.errorMessage = nil }
                            .padding(.bottom, 12)
                    }

                    confirmationInput

                    if isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(auth.isBusy ? "削除しています…" : "確認しています…")
                                .font(DSFont.caption)
                                .foregroundStyle(DS.Gray.g600)
                        }
                        .padding(.top, 16)
                    }

                    PrimaryButton("アカウントを削除する", isDestructive: true) {
                        Task { await submit() }
                    }
                    .disabled(!canExecute)
                    .padding(.top, 16)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(theme.bgApp)
            .navigationTitle("アカウントを削除")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // `isWorking`（= `auth.isBusy || isReauthorizing`）ではなく `auth.isBusy` のみで無効化する。
                    // Apple 再認可（システムシート）が応答を返さない事態が起きても（review.md 中-R1）、
                    // `AppleReauthorizationCoordinator` 側にタイムアウトを入れたとはいえ、
                    // 「ユーザーが必ずシートを閉じられる」ことをこのボタン単体でも保証する
                    Button("閉じる") { dismiss() }
                        .disabled(auth.isBusy)
                }
            }
            .task {
                // プロフィール未取得のままだと `hasPasswordLogin` が false に倒れ、
                // パスワードを持つユーザーにも typed confirmation を出して 400 になる（review.md 中-4）
                if profile.profile == nil { await profile.load() }
            }
            .alert(
                "アカウント",
                isPresented: Binding(
                    get: { alreadyDeletedMessage != nil },
                    set: { if !$0 { alreadyDeletedMessage = nil } }
                ),
                presenting: alreadyDeletedMessage
            ) { _ in
                Button("OK") { finishAfterDeletion() }
            } message: { message in
                Text(message)
            }
        }
    }

    // MARK: - 削除対象の列挙

    private var deletionTargets: some View {
        VStack(alignment: .leading, spacing: 8) {
            deletionTargetRow("名義とファンクラブ会員情報")
            deletionTargetRow("申込の記録")
            deletionTargetRow("発行済みの共有リンク（削除後は相手が開けなくなります）")
        }
        .padding(14)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }

    private func deletionTargetRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("・").font(DSFont.body)
            Text(text).font(DSFont.body)
        }
        .foregroundStyle(DS.Gray.g900)
    }

    // MARK: - サブスク文言（Q6 = A）

    private var subscriptionNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("サブスクリプションについて").font(DSFont.bodyBold)
            Text("アカウントを削除しても、サブスクリプションは自動的には解約されません。App Store の「サブスクリプションを管理」から解約してください。")
                .font(DSFont.caption)
                .foregroundStyle(DS.Gray.g600)
            Link("サブスクリプションを管理", destination: Self.subscriptionManagementURL)
                .font(DSFont.captionBold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }

    // MARK: - 確認入力

    @ViewBuilder
    private var confirmationInput: some View {
        if profile.hasPasswordLogin {
            FormCard {
                FormRow("パスワード") {
                    SecureField("パスワードを入力", text: $password)
                        .font(DSFont.body)
                        .textContentType(.password)
                }
            }
            FormHint("本人確認のため、パスワードを入力してください。")
        } else {
            FormCard {
                FormRow("確認") {
                    TextField("削除", text: $confirmationText)
                        .font(DSFont.body)
                        .autocorrectionDisabled()
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            }
            FormHint("「\(Self.confirmationPhrase)」と入力すると実行できます。")
        }
    }

    // MARK: - 実行

    private func submit() async {
        guard !isWorking else { return }
        errorMessage = nil
        let passwordToSend = profile.hasPasswordLogin ? password : nil

        // Apple ユーザーはトークン失効のため再認可を挟む（`plan.md` §5.3, T-IOS2b）。
        // キャンセルは削除自体を中止（エラー表示しない）。失敗はベストエフォートで nil のまま続行する
        var appleAuthorizationCode: String?
        if profile.authProviders.contains("apple") {
            switch await requestAppleAuthorizationCode() {
            case .authorizationCode(let code):
                appleAuthorizationCode = code
            case .cancelled:
                return
            case .failed:
                appleAuthorizationCode = nil
            }
        }

        do {
            try await auth.deleteAccount(password: passwordToSend, appleAuthorizationCode: appleAuthorizationCode)
            finishAfterDeletion()
        } catch AppError.notFound {
            // 既に削除済み。`AuthStore.deleteAccount` がローカルセッションは消し終えている。
            // 契約 §3.3 は「文言を表示してからログアウト処理」なので、告知の OK でローカルを消す
            alreadyDeletedMessage = AuthErrorText.message(for: AppError.notFound, context: .deleteAccount)
        } catch {
            // 失敗時はログアウトしない。同じ画面で再試行できる
            errorMessage = AuthErrorText.message(for: error, context: .deleteAccount)
        }
    }

    /// Apple 再認可を 1 回だけ走らせる。
    /// コーディネーターは **`@State` が強参照で保持する**（delegate は weak なので式内テンポラリだと解放され得る）。
    private func requestAppleAuthorizationCode() async -> AppleReauthorizationCoordinator.Outcome {
        isReauthorizing = true
        defer {
            isReauthorizing = false
            appleReauthorization = nil
        }
        let coordinator = AppleReauthorizationCoordinator()
        appleReauthorization = coordinator
        return await coordinator.requestAuthorizationCode()
    }

    private func finishAfterDeletion() {
        AccountLocalDataClearing.clearAll(
            profile: profile,
            identityStore: identityStore,
            applicationStore: applicationStore,
            shareLinkStore: shareLinkStore,
            appSettings: appSettings,
            theme: theme
        )
        password = ""
        confirmationText = ""
        dismiss()
    }
}

#Preview {
    AccountDeleteView()
        .environment(AuthStore.preview(state: .signedIn))
        .environment(ProfileStore())
        .environment(IdentityStore())
        .environment(ApplicationStore())
        .environment(ShareLinkStore())
        .environment(AppSettingsStore())
        .environment(\.themeStore, ThemeStore())
}
