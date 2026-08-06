import SwiftUI
import DesignSystem
import Domain

/// 参戦名義帳 Plus ペイウォール（`docs/07` §6.2）。
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(ProfileStore.self) private var profile
    @Environment(PurchasesStore.self) private var purchases
    @Environment(\.themeStore) private var theme

    let trigger: PaywallTrigger

    @State private var selectedPlan: SubscriptionPlan = .annual

    private static let termsURL = URL(string: "https://meigicho.app/terms")!
    private static let privacyURL = URL(string: "https://meigicho.app/privacy")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(headline)
                    .font(DSFont.bigTitle)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Text(bodyText)
                    .font(DSFont.body)
                    .foregroundStyle(DS.Gray.g600)
                    .padding(.bottom, 20)

                SectionHeader("Plusでできること")
                benefitList
                    .padding(.bottom, 20)

                if let message = purchases.statusMessage {
                    FormHint(message).padding(.bottom, 8)
                }
                if let error = purchases.errorMessage {
                    ErrorBar(error) { purchases.clearMessages() }
                        .padding(.bottom, 8)
                }

                planButtons
                    .padding(.bottom, 12)

                if trigger == .identityLimit {
                    TourActionButton("動画を見て30日間だけ1枠増やす") {
                        // リワード広告（Phase 1-11 / AdMob）— 未実装
                        purchases.errorMessage = "リワード広告は準備中です"
                    }
                    .padding(.bottom, 8)
                }

                TourActionButton("あとで") { dismiss() }
                    .padding(.bottom, 16)

                Text("自動更新されます。いつでも解約できます。")
                    .font(DSFont.caption)
                    .foregroundStyle(DS.Gray.g500)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 8)

                HStack(spacing: 16) {
                    linkButton("利用規約") { openURL(Self.termsURL) }
                    linkButton("プライバシーポリシー") { openURL(Self.privacyURL) }
                    linkButton("購入を復元") {
                        Task { await purchases.restore(profile: profile) }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(theme.bgApp)
        .navigationTitle("参戦名義帳 Plus")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("閉じる") { dismiss() }
            }
        }
        .task {
            purchases.clearMessages()
            if let userID = profile.profile?.userID {
                await purchases.configureIfNeeded(userID: userID)
            }
        }
        .disabled(purchases.isBusy)
    }

    private var headline: String {
        switch trigger {
        case .identityLimit: "4件目の名義を登録するには"
        case .shareLinkLimit: "共有リンクは無料版で1本まで"
        case .settings: "参戦名義帳 Plus"
        }
    }

    private var bodyText: String {
        switch trigger {
        case .identityLimit:
            """
            無料版では名義を3件まで登録できます。
            家族や友人の名義もまとめて管理すると、
            「誰の会員資格がいつ切れるか」を一覧で追えるようになります。
            """
        case .shareLinkLimit:
            """
            いま有効な共有リンクが上限に達しています。
            Plus にすると、ツアーごと・相手ごとにリンクを分けて発行でき、
            それぞれ公開する範囲と有効期限を別々に設定できます。
            """
        case .settings:
            """
            名義を無制限に登録でき、広告なしで端末間同期・統計・エクスポートが使えます。
            """
        }
    }

    private var benefitList: some View {
        VStack(alignment: .leading, spacing: 8) {
            benefitRow("名義を無制限に登録")
            benefitRow("広告なし")
            benefitRow("複数の端末で同じ記録を見る")
            benefitRow("名義ごとの当選率などの統計")
            benefitRow("CSV / PDF で書き出し")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.Gray.g200, lineWidth: 1))
    }

    private func benefitRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.primary)
            Text(text).font(DSFont.body)
        }
    }

    @ViewBuilder
    private var planButtons: some View {
        let annual = purchases.offerings.first { $0.plan == .annual }
        let monthly = purchases.offerings.first { $0.plan == .monthly }

        if let annual {
            PrimaryButton(annualButtonTitle(annual)) {
                Task {
                    if await purchases.purchase(plan: .annual, profile: profile) {
                        dismiss()
                    }
                }
            }
            .padding(.bottom, 8)
        }
        if let monthly {
            TourActionButton(monthlyButtonTitle(monthly)) {
                Task {
                    if await purchases.purchase(plan: .monthly, profile: profile) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func annualButtonTitle(_ offering: SubscriptionOffering) -> String {
        if let sub = offering.subtitle {
            return "年額プラン \(offering.priceText)（\(sub)）"
        }
        return "年額プラン \(offering.priceText)"
    }

    private func monthlyButtonTitle(_ offering: SubscriptionOffering) -> String {
        "月額プラン \(offering.priceText)"
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(DSFont.caption)
            .foregroundStyle(DS.Gray.g600)
    }
}
