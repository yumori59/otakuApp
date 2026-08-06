import Foundation

/// identity / application ディープリンクのルーティング（share は `SharedBoardDeepLink` が担当）。
@Observable
@MainActor
public final class DeepLinkCoordinator {
    public var pending: PendingRoute?

    public struct PendingRoute: Equatable {
        public let tab: AppTab
        public let route: AppRoute

        public init(tab: AppTab, route: AppRoute) {
            self.tab = tab
            self.route = route
        }
    }

    public init() {}

    /// `meigicho://identity/<uuid>` / `meigicho://application/<uuid>` を解釈する。
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard url.scheme?.lowercased() == "meigicho" else { return false }
        guard let host = url.host?.lowercased() else { return false }

        let pathID = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let uuid = UUID(uuidString: pathID) else { return false }

        switch host {
        case "identity":
            pending = PendingRoute(tab: .identities, route: .identity(uuid))
            return true
        case "application":
            pending = PendingRoute(tab: .applications, route: .application(uuid))
            return true
        default:
            return false
        }
    }

    public func consume(for tab: AppTab) -> AppRoute? {
        guard pending?.tab == tab else { return nil }
        let route = pending?.route
        pending = nil
        return route
    }
}
