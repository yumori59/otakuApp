import SwiftUI
import DesignSystem
import Domain

struct AccountView: View {
    /// フォーカスが外れたときに保存する項目（AC-ME-01-M）
    enum Field {
        case username
        case appDisplayName
    }

    @Environment(AuthStore.self) private var auth
    @Environment(ProfileStore.self) private var profile
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(ShareLinkStore.self) private var shareLinkStore
    @Environment(AppSettingsStore.self) private var appSettings
    @Environment(PurchasesStore.self) private var purchases
    @Environment(\.themeStore) private var theme

    @State private var usernameDraft = ""
    @State private var appDisplayNameDraft = ""
    @State private var isPasswordChangePresented = false
    @State private var isDeleteAccountPresented = false
    @State private var isPaywallPresented = false
    /// 背景カラーの PATCH をまとめるためのデバウンス
    @State private var themeSaveTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    // ゲスト（未ログイン）でもここに到達する（Q5）。その場合は設定ではなくログイン画面を出す。
    var body: some View {
        Group {
            if auth.isGuest {
                SignInView()
            } else {
                ScrollView {
                    accountSettings
                }
            }
        }
        .background(theme.bgApp)
        .navigationTitle(auth.isGuest ? "ログイン" : "アカウント設定")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.state) {
            // 開いたときに最新を取り直す（他端末での変更を拾う）。
            // **未ログインでは叩かない**（Bearer が無く 401 になるだけ）
            guard !auth.isGuest else { return }
            await profile.load()
            syncDrafts()
        }
        .onChange(of: focusedField) { previous, _ in
            // フォーカスが外れた項目だけを PATCH する
            guard let previous else { return }
            Task { await save(previous) }
        }
        .sheet(isPresented: $isPasswordChangePresented) {
            PasswordChangeView()
        }
        .sheet(isPresented: $isDeleteAccountPresented) {
            AccountDeleteView()
        }
        .sheet(isPresented: $isPaywallPresented) {
            NavigationStack {
                PaywallView(trigger: .settings)
            }
        }
    }

    private var accountSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            BigTitle("アカウント設定")

            if let message = profile.errorMessage ?? profile.state.error?.userMessage {
                ErrorBar(message) {
                    Task {
                        profile.errorMessage = nil
                        await profile.load()
                        syncDrafts()
                    }
                }
                .padding(.bottom, 12)
            }

            ProfileCard(
                initial: (profile.username ?? profile.email ?? "?").prefix(1).uppercased(),
                colorHex: theme.seedHex,
                name: profile.username ?? "ユーザーネーム未設定",
                tag: profile.email ?? ""
            )
            .padding(.bottom, 16)

            SectionHeader("ユーザーネーム")
            FormCard {
                TextField("例）Yuya", text: $usernameDraft)
                    .font(DSFont.body)
                    .padding(14)
                    .focused($focusedField, equals: .username)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
            }
            FormHint("アプリ内での表示名として使われます。")

            SectionHeader("アカウントID")
            accountIDCard

            SectionHeader("アプリ名")
            FormCard {
                TextField("例）参戦名義帳", text: $appDisplayNameDraft)
                    .font(DSFont.body)
                    .padding(14)
                    .focused($focusedField, equals: .appDisplayName)
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }
            }
            FormHint("ホーム画面の見出しなどに使われるアプリの名前です。")

            SectionHeader("背景カラー")
            themeColorCard

            plusSection

            SectionHeader("ログイン方法")
            authProvidersCard

            PrimaryButton("ログアウト", isDestructive: true) {
                // `POST /v1/auth/logout` → Keychain クリア → ログイン画面（Q5）
                Task {
                    await auth.signOut()
                    // 別アカウントでログインし直したときに前のプロフィール・名義・申込・共有リンク・
                    // テーマ設定を残さない（`requirements.md` D4。旧実装は `profile.clear()` のみだった取りこぼし是正）
                    AccountLocalDataClearing.clearAll(
                        profile: profile,
                        identityStore: identityStore,
                        applicationStore: applicationStore,
                        shareLinkStore: shareLinkStore,
                        appSettings: appSettings,
                        theme: theme
                    )
                }
            }
            .disabled(auth.isBusy)
            .padding(.top, 24)

            // ログアウトの直下（`plan.md` §5.2 要件1）。ゲストは冒頭の `auth.isGuest` 分岐で
            // `SignInView` に差し替わるため、この画面自体に到達しない
            PrimaryButton("アカウントを削除", isDestructive: true) {
                isDeleteAccountPresented = true
            }
            .disabled(auth.isBusy)
            .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    // MARK: - アカウント ID

    private var accountIDCard: some View {
        // サーバー発行の `ACC-XXXXXX`。`GET /v1/me` の値が正で、未取得のときだけ
        // サインイン応答のキャッシュ（`AuthStore`）に落とす
        let accountID = profile.accountID ?? auth.accountID
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(accountID ?? "—")
                    .font(DSFont.bodyBold.monospaced())
                Text("ツアー表を共有してもらうときに、相手にこのIDを伝えてください")
                    .font(DSFont.caption)
                    .foregroundStyle(DS.Gray.g600)
            }
            Spacer()
            if let accountID {
                TourActionButton(auth.accountIDCopied ? "コピーしました" : "コピー") {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = accountID
                    #endif
                    auth.accountIDCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        auth.accountIDCopied = false
                    }
                }
            }
        }
        .padding(14)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
        .padding(.bottom, 8)
    }

    // MARK: - Plus

    @ViewBuilder
    private var plusSection: some View {
        SectionHeader("参戦名義帳 Plus")
        if profile.entitlement?.isPlus == true {
            VStack(alignment: .leading, spacing: 8) {
                Text("参戦名義帳 Plus")
                    .font(DSFont.bodyBold)
                if let expires = profile.entitlement?.expiresAt {
                    Text("\(AccountView.dateFormatter.string(from: expires))まで有効")
                        .font(DSFont.caption)
                        .foregroundStyle(DS.Gray.g600)
                }
                TourActionButton("購入を復元") {
                    Task { await purchases.restore(profile: profile) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(DS.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
            .padding(.bottom, 8)
        } else {
            Button { isPaywallPresented = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("参戦名義帳 Plus")
                            .font(DSFont.bodyBold)
                            .foregroundStyle(DS.Gray.g900)
                        Text("名義を無制限に・広告なし・端末間で同期")
                            .font(DSFont.caption)
                            .foregroundStyle(DS.Gray.g600)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(DS.Gray.g400)
                }
                .padding(14)
                .background(DS.surface)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    // MARK: - 背景カラー

    private var themeColorCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("アプリのテーマ色").font(DSFont.bodyBold)
                Text("背景・ナビゲーションバー・ボタンなど、アプリ全体の色に反映されます")
                    .font(DSFont.caption).foregroundStyle(DS.Gray.g600)
            }
            Spacer()
            ColorPicker("", selection: Binding(
                get: { Color(hexString: theme.seedHex) },
                set: { newColor in
                    // `hexString` は `#RRGGBB`（大文字）。BE の `^#[0-9A-Fa-f]{6}$` に合う
                    let hex = newColor.hexString
                    theme.apply(hex: hex)
                    // ColorPicker はドラッグ中も連続で発火する。
                    // **1 操作 = 1 PATCH** になるよう、止まってから送る（サーバーを叩き続けない）
                    themeSaveTask?.cancel()
                    themeSaveTask = Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        await profile.saveThemeColor(hex)
                    }
                }
            ), supportsOpacity: false)
            .labelsHidden()
        }
        .padding(14)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }

    // MARK: - ログイン方法

    private var authProvidersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("連携済みのログイン方法").font(DSFont.bodyBold)
            // 未知の値が増えてもクラッシュせず、既知 3 値だけをラベル化する（AC-ME-04）
            let labels = profile.authProviderLabels
            Text(labels.isEmpty ? "—" : labels.joined(separator: " ・ "))
                .font(DSFont.caption)
                .foregroundStyle(DS.Gray.g600)

            // **`auth_providers` に `"email"` が含まれるときだけ出す**。
            // 無いのに `POST /v1/auth/password` を叩くと `FORBIDDEN` 403（AC-EM-10-M）
            if profile.hasPasswordLogin {
                TourActionButton("パスワードを変更") {
                    isPasswordChangePresented = true
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }

    // MARK: - 保存

    private func syncDrafts() {
        usernameDraft = profile.username ?? ""
        appDisplayNameDraft = profile.appDisplayName ?? ""
    }

    private func save(_ field: Field) async {
        switch field {
        case .username:
            guard usernameDraft != (profile.username ?? "") else { return }
            let saved = await profile.saveUsername(usernameDraft)
            // 失敗したらサーバーの値に戻す（保存できていないのに残さない）
            if !saved { usernameDraft = profile.username ?? "" }
        case .appDisplayName:
            guard appDisplayNameDraft != (profile.appDisplayName ?? "") else { return }
            let saved = await profile.saveAppDisplayName(appDisplayNameDraft)
            if saved {
                // NOTE: `HomeView` は当面 `AppSettingsStore` を見るのでミラーする。
                // `AppSettingsStore` の畳み込みは `UserProfile.appDisplayName` への統合時に行う
                appSettings.appDisplayName = profile.appDisplayName
            } else {
                appDisplayNameDraft = profile.appDisplayName ?? ""
            }
        }
    }
}

#if canImport(UIKit)
import UIKit
#endif
