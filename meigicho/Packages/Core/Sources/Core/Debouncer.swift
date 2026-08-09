import Foundation

/// 連続呼び出しを畳んで「最後の 1 回だけ」を遅延実行する（`docs/05` §5 の「編集後3秒デバウンス」）。
///
/// 座席の打鍵のように 1 文字ごとに `update` が飛ぶ経路から同期を叩くと、
/// リクエストが張り付いてしまう。`call` のたびに前回の待機をキャンセルし、
/// 静止してから `interval` 経過した時点で 1 回だけ実行する。
///
/// - Note: `Task.sleep` ベースなのでキャンセルは即座に効く。actor なので
///   複数スレッドから `call` されても待機タスクの入れ替えは直列化される。
public actor Debouncer {
    private let interval: Duration
    private var pending: Task<Void, Never>?

    public init(interval: Duration) {
        self.interval = interval
    }

    public init(seconds: Double) {
        self.init(interval: .seconds(seconds))
    }

    /// 直近の待機を捨てて、`interval` 後に `operation` を 1 回実行する予約を入れ直す。
    public func call(_ operation: @escaping @Sendable () async -> Void) {
        pending?.cancel()
        pending = Task { [interval] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                // 次の `call` に置き換えられた（= まだ入力が続いている）
                return
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    /// 待機中の実行を取り消す（画面破棄・ログアウトなど）。
    public func cancel() {
        pending?.cancel()
        pending = nil
    }

    /// 待機中の実行があれば完了まで待つ。テスト用。
    public func drain() async {
        await pending?.value
    }
}
