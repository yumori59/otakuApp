import Foundation

/// ローカル SSoT への書き込み（create / update / delete）が起きたことだけを伝える細い口。
///
/// `docs/05` §5 のトリガ表「編集後3秒デバウンス — Repository の書き込みフック」の受け口。
/// Repository は `SyncEngine` を知らない（Composition Root で別々に組み立てられる）ため、
/// **同期そのものではなく「書いた」という事実だけ**を通知し、デバウンスと同期起動は
/// Composition Root（`AppEnvironment`）が担う。
///
/// - Important: `didWrite()` は Repository の actor 内から同期的に呼ばれる。
///   重い処理・`await` はここでしない（実装側で `Task` に逃がす）。
public struct LocalWriteObserver: Sendable {
    /// 何もしない既定。テストと `SyncEngine` を持たない構成（UI テスト）で使う。
    public static let noop = LocalWriteObserver {}

    private let handler: @Sendable () -> Void

    public init(_ handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    public func didWrite() {
        handler()
    }
}
