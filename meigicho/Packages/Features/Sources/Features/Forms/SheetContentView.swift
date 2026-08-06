import SwiftUI
import Domain

struct SheetContentView: View {
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
