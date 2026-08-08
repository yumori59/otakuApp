import SwiftUI
import DesignSystem
import Domain
import Core

#if canImport(UIKit)
import UIKit
#endif

/// 名義サマリ（`scope_type: "identity_summary"`）の共有プレビューとリンク発行。
///
/// - 履歴公開トグルは `PATCH /v1/identities/:id`（`IdentityStore.toggleHistoryVisible`）に届く。
///   楽観更新 → 失敗時は巻き戻し + `actionError`（T2 実装）
/// - **`identity_summary` に `permission` は送れない**（`write` は tour 専用 = 400）。
///   このため権限の選択 UI を置かない
struct SharePreviewView: View {
    @Environment(IdentityStore.self) private var identityStore
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(StatsStore.self) private var statsStore
    @Environment(ShareLinkStore.self) private var shareLinks
    @Environment(AuthStore.self) private var auth
    @Environment(\.themeStore) private var theme

    @State private var didCopy = false
    @State private var recipientText = ""
    @State private var recipientError: String?
    @State private var newRecipientText = ""

    private var shareState: ShareLinkState { shareLinks.identitySummaryState }

    /// 発行フォームの入力を分割しただけの ID（形式検証前）。
    /// **0 件では発行させない**（招待はアクセス制限そのもの — `ShareRecipientsView` と同じ制約）
    private var parsedRecipientIDs: [String] {
        AccountIDValidator.parse(recipientText)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BigTitle("共有プレビュー", subtitle: "共有リンクを開いた相手には、この内容が表示されます")

                if let error = identityStore.actionError {
                    ErrorBar(error.userMessage).padding(.bottom, 12)
                }
                if let error = shareLinks.actionError {
                    ErrorBar(error.userMessage).padding(.bottom, 12)
                }

                SectionHeader("名義ごとの公開設定")
                CardList {
                    ForEach(Array(identityStore.identities.enumerated()), id: \.element.id) { index, identity in
                        HStack(spacing: 12) {
                            AvatarView(name: identity.displayName, colorHex: identity.colorHex)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(identity.displayName).font(DSFont.bodyBold)
                                Text(identity.historyVisible
                                    ? "当落履歴を公開（当選\(statsStore.winCount(for: identity.id, fallback: applicationStore.winCount(for: identity.id)))回・申込\(applicationStore.applications(for: identity.id).count)件）"
                                    : "当落履歴は非公開")
                                    .font(DSFont.caption)
                                    .foregroundStyle(DS.Gray.g600)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { identity.historyVisible },
                                set: { _ in identityStore.toggleHistoryVisible(identity.id) }
                            ))
                            .labelsHidden()
                        }
                        .padding(14)
                        if index < identityStore.identities.count - 1 { Divider() }
                    }
                }

                SectionHeader("プレビュー")
                CardList {
                    ForEach(identityStore.identities) { identity in
                        let apps = applicationStore.applications(for: identity.id)
                        let wins = apps.filter { $0.status == .won }.count
                        VStack(alignment: .leading, spacing: 4) {
                            Text(identity.displayName)
                                .font(DSFont.bodyBold)
                                .foregroundStyle(identity.historyVisible ? DS.Gray.g900 : DS.Gray.g400)
                            Text(identity.historyVisible ? "当選 \(wins)回 ／ 申込 \(apps.count)件" : "非公開")
                                .font(DSFont.caption)
                                .foregroundStyle(identity.historyVisible ? DS.Gray.g600 : DS.Gray.g400)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 14)

                linkSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle("共有プレビュー")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            shareLinks.clearActionError()
            await shareLinks.load()
        }
    }

    // MARK: - リンクの発行 / 停止

    @ViewBuilder
    private var linkSection: some View {
        SectionHeader("共有リンク")

        if let issued = shareLinks.lastIssued, issued.link.scopeType == .identitySummary {
            // `url` は発行レスポンスにしか無い（C4）。画面を離れると再表示できない
            FormCard {
                Text(issued.url)
                    .font(DSFont.caption)
                    .foregroundStyle(DS.Gray.g900)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            FormHint("このリンクは画面を離れると再表示できません。いまコピーして共有相手に渡してください。")
            PrimaryButton(didCopy ? "リンクをコピーしました" : "共有リンクをコピー") {
                #if canImport(UIKit)
                UIPasteboard.general.string = issued.url
                #endif
                didCopy = true
            }
            .padding(.top, 8)
        }

        switch shareState {
        case .shared(let link):
            FormHint("共有中（\(link.accessCountsSummary)）"
                + (link.expiresAt.map { " ・ 期限 \(DateFormatting.formatDate($0, withWeekday: false))" } ?? ""))
            recipientsSection(link)
            PrimaryButton(shareLinks.isSaving ? "停止中…" : "共有を停止", isDestructive: true) {
                Task { await shareLinks.revoke(link.id) }
            }
            .padding(.top, 8)
            .disabled(shareLinks.isSaving)
        case .unshared, .ended:
            if case .ended = shareState {
                FormHint("前回の共有は終了しています。新しくリンクを作ると、前のリンクは使えないままです。")
            }
            creationForm
        }

        accountIDHint
    }

    // MARK: - 発行フォーム（招待相手の指定）

    /// **0 件では発行させない**（招待はアクセス制限そのもの）。
    /// 実在確認はしない — 未知の ACC-ID はサーバーが `.shareRecipientUnknown` を返し、`actionError` の
    /// `ErrorBar` に文言で出る（IOS-4）
    @ViewBuilder
    private var creationForm: some View {
        SectionHeader("共有相手のID（必須）")
        FormCard {
            FormRow("カンマ区切りで複数指定できます") {
                FormTextField("例）ACC-1A2B3C, ACC-9F8E7D", text: $recipientText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
        }
        if let recipientError {
            FormHint(recipientError, isError: true)
        }
        FormHint("IDは相手の「アカウント設定」画面で確認できます。ここに入れたアカウントだけがこの共有リンクを開けます。少なくとも1件は指定してください。")

        PrimaryButton(shareLinks.isSaving ? "共有リンクを作成中…" : "共有リンクを作成") {
            Task { await createLink() }
        }
        .padding(.top, 8)
        .disabled(shareLinks.isSaving || parsedRecipientIDs.isEmpty)
    }

    // MARK: - 招待の追加 / 削除（発行後）

    /// 招待は**アクセス制限そのもの**。ここに載っているアカウントだけが開ける。
    @ViewBuilder
    private func recipientsSection(_ link: Domain.ShareLink) -> some View {
        SectionHeader("共有相手（ここに入れたアカウントだけが見られます）")
        FormCard {
            if link.recipients.isEmpty {
                FormRow("招待済みのアカウントはありません") {
                    Text("このリンクはまだ誰も開けません。下からアカウントIDを追加してください。")
                        .font(DSFont.caption)
                        .foregroundStyle(DS.Gray.g500)
                }
            } else {
                ForEach(link.recipients) { recipient in
                    FormRow(recipient.displayLabel) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipient.accountID)
                                    .font(DSFont.caption)
                                    .foregroundStyle(DS.Gray.g600)
                                Text(recipient.hasNeverViewed ? "未閲覧" : "閲覧済み")
                                    .font(DSFont.caption)
                                    .foregroundStyle(DS.Gray.g500)
                            }
                            Spacer()
                            Button("削除") {
                                Task { await shareLinks.removeRecipient(shareID: link.id, accountID: recipient.accountID) }
                            }
                            .font(DSFont.caption)
                            .foregroundStyle(DS.error)
                            .disabled(shareLinks.isSaving)
                        }
                    }
                }
            }
        }

        FormCard {
            FormRow("アカウントIDを追加（カンマ区切りで複数可）") {
                FormTextField("例）ACC-1A2B3C", text: $newRecipientText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
        }
        PrimaryButton(shareLinks.isSaving ? "追加中…" : "招待を追加") {
            Task { await addRecipients(link) }
        }
        .padding(.top, 8)
        .disabled(shareLinks.isSaving || AccountIDValidator.parse(newRecipientText).isEmpty)
    }

    @ViewBuilder
    private var accountIDHint: some View {
        if let accountID = auth.accountID {
            FormHint("あなたのアカウントID: \(accountID)（アカウント設定で確認・コピーできます）")
                .padding(.top, 12)
        }
    }

    // MARK: - 操作

    private func createLink() async {
        let ids = AccountIDValidator.parse(recipientText)
        // 送る前に形式を弾く（`ShareRecipientsView` と同じ検証）。実在確認はしない（IOS-4）
        switch AccountIDValidator.validate(ids) {
        case .invalidFormat(let invalid):
            recipientError = "アカウントIDの形式が正しくありません: \(invalid.joined(separator: "、"))"
            return
        case .tooMany:
            recipientError = "共有相手は \(AccountIDValidator.maxRecipients) 件までです"
            return
        case .valid:
            recipientError = nil
        }

        didCopy = false
        await shareLinks.createIdentitySummaryLink(recipientIDs: ids)
    }

    /// 発行後に招待を追加する。**存在確認はサーバー任せ**（IOS-4）。
    /// 未知の ACC-ID は `AppError.shareRecipientUnknown` → `actionError` の `ErrorBar` に文言で出る。
    private func addRecipients(_ link: Domain.ShareLink) async {
        let ids = AccountIDValidator.parse(newRecipientText)
        guard !ids.isEmpty else { return }
        if await shareLinks.addRecipients(shareID: link.id, accountIDs: ids) != nil {
            newRecipientText = ""
        }
    }
}
