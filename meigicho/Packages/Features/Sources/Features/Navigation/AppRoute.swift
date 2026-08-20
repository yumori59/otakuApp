import Foundation
import Domain

public enum AppRoute: Hashable {
    case identity(UUID)
    case application(UUID)
    case sharePreview
    case account
    /// 受信箱（**自分が招待された共有**の一覧）。`GET /v1/shares/received`
    case sharedInbox
    /// 共有ボード（**受け取り側**）。`share_id` で addressing する（`api-contract-delta.md` §4.2）。
    ///
    /// token 起点だった旧 `.sharedBoard(token:)` は廃止。ディープリンクの token は
    /// `redeem`（`SharedInboxRepository.redeem(token:)`）で `share_id` に交換してからここへ来る
    case sharedBoard(shareID: UUID)
}

public enum AppSheet: Identifiable, Hashable {
    case addIdentity
    case addMembership(identityID: UUID)
    case addApplication
    /// 申込編集（T5・`docs/plans/application-edit/plan.md`）。`ApplicationDetailView` の「編集」から開く
    case editApplication(id: UUID)
    /// 名義編集（TE-6・`docs/plans/identity-edit-and-delete/plan.md`）。`IdentityDetailView` の「編集」から開く
    case editIdentity(id: UUID)
    /// 会員情報編集（TE-6）。`IdentityDetailView` の会員情報カードタップから開く
    case editMembership(id: UUID)
    case shareRecipients(tourName: String)
    /// 未ログインで書き込み操作が要求されたときのログイン誘導（Q5）。
    /// `reason` は「なぜログインが必要か」の 1 行。閲覧からの導線では nil
    case signIn(reason: String?)
    /// Plus ペイウォール（`docs/07` §6）。
    case paywall(PaywallTrigger)

    public var id: String {
        switch self {
        case .addIdentity: "addIdentity"
        case .addMembership(let id): "addMembership-\(id)"
        case .addApplication: "addApplication"
        case .editApplication(let id): "editApplication-\(id)"
        case .editIdentity(let id): "editIdentity-\(id)"
        case .editMembership(let id): "editMembership-\(id)"
        case .shareRecipients(let tour): "shareRecipients-\( tour)"
        case .signIn: "signIn"
        case .paywall(let trigger): "paywall-\(trigger.rawValue)"
        }
    }
}

public enum AppTab: Int, CaseIterable {
    case home = 0
    case identities = 1
    case applications = 2

    var title: String {
        switch self {
        case .home: "ホーム"
        case .identities: "名義"
        case .applications: "申込"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .identities: "person.2.fill"
        case .applications: "ticket.fill"
        }
    }
}
