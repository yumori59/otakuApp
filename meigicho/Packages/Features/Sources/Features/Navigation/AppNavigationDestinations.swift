import SwiftUI

// NOTE(T0): 旧 `Detail/DetailViews.swift` から機械的に切り出したもの（振る舞い不変）。
struct AppNavigationDestinations: ViewModifier {
    @Binding var path: NavigationPath

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .identity(let id):
                    IdentityDetailView(path: $path, identityID: id)
                case .application(let id):
                    ApplicationDetailView(path: $path, applicationID: id)
                case .sharePreview:
                    SharePreviewView()
                case .account:
                    AccountView()
                case .sharedInbox:
                    SharedInboxView(path: $path)
                case .sharedBoard(let shareID):
                    SharedBoardView(shareID: shareID)
                }
            }
    }
}

extension View {
    func appNavigationDestinations(path: Binding<NavigationPath>) -> some View {
        modifier(AppNavigationDestinations(path: path))
    }
}
