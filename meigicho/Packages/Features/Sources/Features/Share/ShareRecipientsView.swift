import SwiftUI
import DesignSystem
import Domain
import Core

#if canImport(UIKit)
import UIKit
#endif

/// ツアーの共有リンクを発行 / 停止する画面（オーナー側）。
///
/// - **`permission` は発行時にしか決められない**（変更する API が無い）。
///   変えたいときは一度停止して作り直す（`api-contract-delta.md` §3）
/// - `url` は発行レスポンスにしか無いので、**この画面を閉じるとコピーできなくなる**（C4）
/// - `write` の公演数上限（free = 3 公演）は**サーバーが判定する**。
///   ここで公演数を数えて選択肢を消さない（IOS-4 / AC-SH-10-M）
struct ShareRecipientsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(AuthStore.self) private var auth
    @Environment(ShareLinkStore.self) private var shareLinks
    @Environment(ProfileStore.self) private var profile
    @Environment(SheetPresenter.self) private var sheetPresenter
    @Environment(\.themeStore) private var theme

    let tourName: String

    @State private var recipientText = ""
    @State private var permission: SharePermission = .read
    @State private var recipientError: String?
    @State private var didCopy = false

    /// 共有対象のツアー。`AppSheet` はツアー名しか運ばないのでここで引き直す。
    private var tourID: UUID? {
        applicationStore.allTourGroups().first { $0.tourName == tourName }?.id
    }

    private var shareState: ShareLinkState {
        guard let tourID else { return .unshared }
        return shareLinks.shareState(forTour: tourID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BigTitle("ツアー表を共有", subtitle: tourName)

                if let error = shareLinks.actionError {
                    // 発行 / 停止の失敗。**プラン上限（本数・公演数）もここに文言として出る**
                    ErrorBar(error.userMessage)
                        .padding(.bottom, 12)
                }

                if tourID == nil {
                    FormHint("このツアーが見つかりませんでした。申込一覧を更新してからもう一度お試しください。")
                } else {
                    switch shareState {
                    case .shared(let link):
                        activeLinkSection(link)
                    case .unshared, .ended:
                        creationForm
                    }
                }

                if let issued = shareLinks.lastIssued, issued.link.scopeID == tourID {
                    issuedLinkSection(issued)
                }

                accountIDHint
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle("ツアー表を共有")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("閉じる") {
                    shareLinks.clearIssued()
                    dismiss()
                }
            }
        }
        .task {
            // 前の画面で出た発行エラーを持ち越さない
            shareLinks.clearActionError()
            // 共有状態の正はサーバー。シートを開くたびに取り直す（他端末で停止された場合など）
            await shareLinks.load()
        }
        .onAppear {
            guard let tourID else { return }
            recipientText = shareLinks.recipientIDs(forTour: tourID).joined(separator: ", ")
            if let link = shareState.link {
                permission = link.permission
            }
        }
    }

    // MARK: - 発行フォーム

    @ViewBuilder
    private var creationForm: some View {
        if case .ended(let link) = shareState {
            FormHint("前回の共有は終了しています（\(link.accessCountsSummary)）。新しくリンクを作ると、前のリンクは使えないままです。")
                .padding(.bottom, 12)
        }

        SectionHeader("共有相手にできること")
        SegmentedPicker(
            options: [
                (SharePermission.read, SharePermission.read.label),
                (SharePermission.write, SharePermission.write.label)
            ],
            selection: $permission
        )
        FormHint(permission == .write
            ? "共有相手が当落と座席を書き込めます。無料プランでは公演数の上限があり、超えている場合は共有時にお知らせします。"
            : "共有相手は表を見るだけで、書き換えはできません。")
            .padding(.bottom, 4)

        SectionHeader("共有相手のID（任意）")
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
        FormHint("IDは相手の「アカウント設定」画面で確認できます。共有リンクはURLを知っている人なら誰でも開けるため、IDの入力はアクセス制限ではなく記録用である点にご注意ください。")

        PrimaryButton(shareLinks.isSaving ? "共有リンクを作成中…" : "この設定で共有する") {
            Task { await createLink() }
        }
        .padding(.top, 16)
        .disabled(shareLinks.isSaving)
    }

    // MARK: - 共有中

    @ViewBuilder
    private func activeLinkSection(_ link: Domain.ShareLink) -> some View {
        SectionHeader("共有中")
        FormCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(link.permissionLabel).font(DSFont.bodyBold)
                Text(link.accessCountsSummary)
                    .font(DSFont.caption).foregroundStyle(DS.Gray.g600)
                if let expiresAt = link.expiresAt {
                    Text("期限 \(DateFormatting.formatDate(expiresAt))")
                        .font(DSFont.caption).foregroundStyle(DS.Gray.g600)
                }
                Text("共有相手: \(link.sharedWithAccountIDs.isEmpty ? "未指定" : link.sharedWithAccountIDs.joined(separator: "、"))")
                    .font(DSFont.caption).foregroundStyle(DS.Gray.g600)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        FormHint("共有相手にできること（閲覧のみ／編集も許可）は、あとから変更できません。変えたいときは共有を停止してから作り直してください。")

        PrimaryButton(shareLinks.isSaving ? "停止中…" : "共有を停止", isDestructive: true) {
            Task {
                await shareLinks.revoke(link.id)
            }
        }
        .padding(.top, 16)
        .disabled(shareLinks.isSaving)
    }

    // MARK: - 発行直後（token / url が取れるのはここだけ）

    @ViewBuilder
    private func issuedLinkSection(_ issued: IssuedShareLink) -> some View {
        SectionHeader("共有リンク")
        FormCard {
            Text(issued.url)
                .font(DSFont.caption)
                .foregroundStyle(DS.Gray.g900)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        FormHint("このリンクはこの画面を閉じると再表示できません。いまコピーして共有相手に渡してください。")
        PrimaryButton(didCopy ? "リンクをコピーしました" : "リンクをコピー") {
            #if canImport(UIKit)
            UIPasteboard.general.string = issued.url
            #endif
            didCopy = true
        }
        .padding(.top, 8)
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
        guard let tourID else { return }

        if case .unshared = shareState {
            let entitlement = profile.entitlement
                ?? Entitlement(plan: .free, identityLimit: 3, shareLimit: 1)
            if !entitlement.canCreateShareLink(activeLinkCount: shareLinks.activeLinkCount()) {
                sheetPresenter.presentPaywall(.shareLinkLimit)
                return
            }
        }

        let ids = AccountIDValidator.parse(recipientText)
        // 送る前に形式を弾く（AC-SH-02-T）。**公演数の上限はここで判定しない**（IOS-4）
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
        await shareLinks.createTourLink(tourID: tourID, permission: permission, recipientIDs: ids)
    }
}
