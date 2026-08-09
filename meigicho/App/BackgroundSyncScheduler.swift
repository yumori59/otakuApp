import BackgroundTasks
import Foundation
import os
import DataStore
import Domain

/// `BGAppRefreshTask` による起動前同期（`docs/05` §5 のトリガ表 / ios-sync-engine T5）。
///
/// - 実行機会は **OS 任せで保証されない**。`earliestBeginDate: +15 分` は「これより早くは動かすな」の下限であり、
///   予約でも約束でもない。ここが動かなくても起動・前面復帰のトリガで最新化できる設計を崩さない
/// - 猶予は約 30 秒。`expirationHandler` で走行中 `Task` を `cancel()` し、
///   **`setTaskCompleted(success:)` を必ず 1 回だけ**呼ぶ（二重呼び出しは異常終了）
/// - `BGAppRefreshTask` は 1 回きりなので、ハンドラの入口で次回分を積み直す
@MainActor
final class BackgroundSyncScheduler {
    /// `project.yml` の `BGTaskSchedulerPermittedIdentifiers` と**必ず一致させる**。
    /// 未登録の識別子を `submit` すると `BGTaskScheduler.Error.notPermitted` になる
    static let taskIdentifier = "jp.meigicho.app.sync-refresh"

    /// 次回実行の下限（`docs/05` §5: +15min）
    private static let earliestInterval: TimeInterval = 15 * 60
    /// OS の猶予（約 30 秒）より手前で必ず畳むための自衛タイマー
    private static let watchdogSeconds: Double = 25

    private static let log = Logger(subsystem: "jp.meigicho.app", category: "sync")

    private let syncEngine: SyncEngine?
    private var isRegistered = false
    private var runningTask: Task<Void, Never>?

    init(syncEngine: SyncEngine?) {
        self.syncEngine = syncEngine
    }

    /// ハンドラを登録する。**アプリ起動完了前**（`MeigichoApp.init`）に呼ぶ必要がある。
    /// 同一識別子の二重登録は例外になるため多重呼び出しを弾く。
    func register() {
        guard !isRegistered, syncEngine != nil else { return }
        isRegistered = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil // メインキュー
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { [weak self] in
                self?.handle(refreshTask)
            }
        }
    }

    /// 次回の実行を予約する。バックグラウンド移行時とハンドラ実行時に呼ぶ。
    /// シミュレータでは受理されても自然発火しない（下の「手動確認」参照）。
    func schedule() {
        guard isRegistered else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.earliestInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // 予約に失敗しても起動・前面復帰の同期で追いつく。ユーザーには見せない。
            // 本文は載せない（`Core.AppLogger` と同じ方針 — NFR-4）
            Self.log.debug("event=bg_refresh_submit_failed")
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        // 1 回きりなので、走らせる前に次回分を積む
        schedule()

        let gate = TaskCompletionGate(task: task)
        guard let syncEngine else {
            gate.complete(success: true)
            return
        }

        // 背景実行では画面が無いので Store の読み直しはしない。ローカル SSoT の更新だけで足りる
        // （前面復帰時に `MeigichoApp.syncAndRefresh` が読み直す）
        let work = Task { await syncEngine.syncNow(reason: .launch) }
        runningTask = work

        task.expirationHandler = {
            work.cancel()
            gate.complete(success: false)
        }

        Task { @MainActor in
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(Self.watchdogSeconds))
                guard !Task.isCancelled else { return }
                work.cancel()
                gate.complete(success: false)
            }
            await work.value
            watchdog.cancel()
            self.runningTask = nil
            gate.complete(success: true)
        }
    }
}

/// `setTaskCompleted(success:)` を**高々 1 回**に絞る門。
/// `expirationHandler`・watchdog・正常完了が競合しうるのでロックで直列化する。
/// `BGTask` は `Sendable` ではないが、この型の中でしか触らず呼び出しはロック下に閉じている。
private final class TaskCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isCompleted = false
    private let task: BGTask

    init(task: BGTask) {
        self.task = task
    }

    func complete(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCompleted else { return }
        isCompleted = true
        task.setTaskCompleted(success: success)
    }
}
