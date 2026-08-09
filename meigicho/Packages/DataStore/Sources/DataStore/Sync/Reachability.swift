import Foundation
import Network
import SystemConfiguration

/// 到達性の薄いラッパ（`docs/05` §5）。
///
/// `NWPathMonitor` を actor で包み、`pathUpdateHandler` で `isOnline`（`path.status == .satisfied`）と
/// `isConstrained`（低データモード）を更新する。**低データモードでは自動同期を止め手動のみ**にする判断は
/// `SyncEngine.runCycle` 側（`constrained && reason != .manual` で早期 return）。
///
/// - Note: `import Network` は Apple の Network.framework を指す。**同名のローカル SPM パッケージを作らないこと**
///   （自作 HTTP 層は `Packages/Networking` に改名済み）。Xcode 統合 SPM ではパッケージのモジュール検索パスが
///   全ターゲットで共有されるため、`Network` という名前のローカルモジュールがあると
///   ビルド順しだいでそちらが優先され `cannot find type 'NWPathMonitor'` になる（IOS-12）。
/// - Note: `pathUpdateHandler` は actor 外のキューから呼ばれるので `Task { await ... }` で actor に畳む。
public actor Reachability {
    public private(set) var isOnline: Bool = true
    public private(set) var isConstrained: Bool = false

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "jp.meigicho.reachability")

    public init() {}

    /// 監視を開始する。多重呼び出しは無視する（起動時 `.task` とテストの両方から呼ばれうる）。
    public func start() {
        guard monitor == nil else {
            refresh()
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let constrained = path.isConstrained
            Task { await self?.apply(isOnline: online, isConstrained: constrained) }
        }
        monitor.start(queue: queue)
        // `pathUpdateHandler` の初回コールバックが来るまでの空白を埋める。
        // `start(queue:)` は非同期で、直後の `currentPath` はまだ既定値（`.unsatisfied`）のことがある。
        // ここで `isOnline = false` に倒すと**起動同期が `.offline` で空振りし、
        // 前面復帰まで同期されない**。満たされていないときだけ `SCNetworkReachability` の
        // ワンショットで裏を取る（本当にオフラインなら false のまま）
        let initialPath = monitor.currentPath
        if initialPath.status == .satisfied {
            apply(path: initialPath)
        } else {
            apply(isOnline: Self.checkOnline(), isConstrained: initialPath.isConstrained)
        }
    }

    public func stop() {
        monitor?.cancel()
        monitor = nil
    }

    /// 現在値を取り直す。監視中なら `NWPathMonitor.currentPath`、
    /// 未開始なら `SCNetworkReachability` のワンショットにフォールバックする。
    public func refresh() {
        if let monitor {
            apply(path: monitor.currentPath)
            return
        }
        isOnline = Self.checkOnline()
        // 監視していない間は低データモードを判定できない。自動同期を止めない側（false）に倒す
        isConstrained = false
    }

    /// テスト用に状態を上書きする。
    public func set(isOnline: Bool, isConstrained: Bool = false) {
        self.isOnline = isOnline
        self.isConstrained = isConstrained
    }

    private func apply(path: NWPath) {
        apply(isOnline: path.status == .satisfied, isConstrained: path.isConstrained)
    }

    private func apply(isOnline: Bool, isConstrained: Bool) {
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
