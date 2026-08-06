import Foundation
import Domain

public enum AppRoute: Hashable {
    case identity(UUID)
    case application(UUID)
    case sharePreview
    case account
    /// 共有ボード（**受け取り側**）。`token` が唯一の資格情報で、
    /// 自分のアカウント（Bearer）とは無関係の経路（`contract-mapping.md` §5.1）
    case sharedBoard(token: String)
}

public enum AppSheet: Identifiable, Hashable {
    case addIdentity
    case addMembership(identityID: UUID)
    case addApplication
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
