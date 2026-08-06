import Foundation
import SystemConfiguration

/// 到達性の薄いラッパ（`docs/05` §5）。
/// Apple `Network.framework` は SPM の `Network` パッケージと衝突するため SystemConfiguration を使う。
public actor Reachability {
    public private(set) var isOnline: Bool = true
    public private(set) var isConstrained: Bool = false

    public init() {}

    public func start() {
        refresh()
    }

    public func stop() {}

    public func refresh() {
        isOnline = Self.checkOnline()
        // 低データモードは NWPathMonitor 相当が無いため、当面 false 固定（T5 で強化可）
        isConstrained = false
    }

    /// テスト用に状態を上書きする。
    public func set(isOnline: Bool, isConstrained: Bool = false) {
        self.isOnline = isOnline
        self.isConstrained = isConstrained
    }

    private static func checkOnline() -> Bool {
        var zero = sockaddr_in()
        zero.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zero.sin_family = sa_family_t(AF_INET)

        guard let reachability = withUnsafePointer(to: &zero, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }) else {
            return true
        }

        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else {
            return true
        }

        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        return isReachable && !needsConnection
    }
}
