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
    @Environment(\.themeStore) private var theme

    @State private var didCopy = false

    private var shareState: ShareLinkState { shareLinks.identitySummaryState }

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
            PrimaryButton(shareLinks.isSaving ? "停止中…" : "共有を停止", isDestructive: true) {
                Task { await shareLinks.revoke(link.id) }
            }
            .padding(.top, 8)
            .disabled(shareLinks.isSaving)
        case .unshared, .ended:
            if case .ended = shareState {
                FormHint("前回の共有は終了しています。新しくリンクを作ると、前のリンクは使えないままです。")
            }
            PrimaryButton(shareLinks.isSaving ? "共有リンクを作成中…" : "共有リンクを作成") {
                didCopy = false
                Task { await shareLinks.createIdentitySummaryLink() }
            }
            .padding(.top, 8)
            .disabled(shareLinks.isSaving)
        }
    }
}
