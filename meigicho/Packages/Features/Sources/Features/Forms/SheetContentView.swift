import SwiftUI
import Domain
import DesignSystem

struct SheetContentView: View {
    @Environment(ApplicationStore.self) private var applicationStore
    @Environment(IdentityStore.self) private var identityStore
    let sheet: AppSheet
    let onIdentitySaved: (UUID) -> Void

    var body: some View {
        NavigationStack {
            switch sheet {
            case .addIdentity:
                AddIdentityView(onSaved: onIdentitySaved)
            case .addMembership(let identityID):
                AddMembershipView(identityID: identityID)
            case .addApplication:
                AddApplicationView()
            case .editApplication(let id):
                if let entry = applicationStore.application(for: id) {
                    ApplicationFormView(mode: .edit(entry))
                } else {
                    EmptyStateView("申込が見つかりません")
                }
            case .editIdentity(let id):
                if let identity = identityStore.identity(for: id) {
                    IdentityFormView(mode: .edit(identity))
                } else {
                    EmptyStateView("名義が見つかりません")
                }
            case .editMembership(let id):
                if let membership = identityStore.memberships.first(where: { $0.id == id }) {
                    MembershipFormView(mode: .edit(membership))
                } else {
                    EmptyStateView("会員情報が見つかりません")
                }
            case .shareRecipients(let tourName):
                ShareRecipientsView(tourName: tourName)
            case .signIn(let reason):
                // 未ログインで書き込み操作が押されたときの誘導（Q5）
                SignInSheetView(reason: reason)
            case .paywall(let trigger):
                PaywallView(trigger: trigger)
            }
        }
    }
}
