# ios-sync-engine T3 + T4 — Code Review

**日付**: 2026-08-07
**対象**: `work/ios-sync-engine-t3-t4`（`0593c5d` T3 / `a5c1d90` T4）+ 本レビューでの修正コミット
**レビュアー**: code-reviewer（実装者とは別セッション）
**スコープ外**: T5（デバウンス・低データモード）、AdMob / 統計 UI、CRDT、共有リンク・billing の sync 対象化

## レビュー結果サマリ

| 区分 | 初回 | 修正後 |
|---|---|---|
| 重大 (Must Fix) | 2 | **0** |
| 中 (Should Fix) | 5 | 5（申し送り） |
| 軽微 / 提案 | 4 | 4 |

検証: `swift test`（DataStore）19 tests 0 failures / `xcodebuild ... build` **BUILD SUCCEEDED**。

---

## 重大 (Must Fix) — 本レビューで修正済み

### 1. オフライン起動で `.signedOut` になり、ローカル DB とカーソルが全消しされる（AC-SY-04 違反 / データ喪失）

- 発生源: `meigicho/App/MeigichoApp.swift:135-146`（修正前）
  ```swift
  guard authStore.state == .signedIn else {
      if authStore.state == .signedOut { await environment.resetLocalStore() }
      return
  }
  ```
- 一次ソース: `meigicho/Packages/Domain/Sources/Domain/AuthStore.swift:121-126`
  ```swift
  case .unavailable(let error):
      // token は消さない。通信が戻れば復帰できる
      user = nil
      state = .signedOut
  ```
  `meigicho/Packages/Network/Sources/Network/ApiClient.swift:217-230` の `restoreSession()` は
  **オフライン（refresh 失敗が session-ending でない）で `.unavailable` を返す**。
- 影響: 機内モード等でコールドスタートすると `state == .signedOut` になり、
  `resetLocalStore()` が `ApplicationCompanionRecord` 〜 `OutboxEntry` まで全削除。
  **オフライン中に作った未送信の編集がそのまま消える**（AC-SY-04「オフライン中の create/update/delete が
  再起動後も失われない」に真っ向から反する）。同期カーソルも消えるので次回全件再 pull。
- 修正: `AppEnvironment.resetLocalStoreIfSessionCleared()` を追加し、
  **Keychain の refresh token が実際に消えているときだけ**（明示ログアウト / アカウント削除 /
  サイレントログアウト = `clearLocalSession()` / `handleSessionEnded()` 経路）ローカルを消す。
  - `meigicho/App/AppEnvironment.swift:107-117`
  - `meigicho/App/MeigichoApp.swift:135-147`

### 2. pull した内容が画面に反映されない（縦串が閉じていない / IOS-3）

- `SyncEngine` の pull は SwiftData に書き込むだけで、`IdentityStore` / `ApplicationStore` は
  再読込されない。`MeigichoApp.swift:107-110` の `load()` は `.task(id: authStore.state)` の
  **同期サイクルと並行に**走るだけで、フォアグラウンド復帰（`onChange(of: scenePhase)`）や
  手動再試行（`SyncActionBridge`）の後は一切リロードされない。
- 影響: `plan.md` 手動確認 1「端末 A で名義追加 → 端末 B pull で見える」が成立しない
  （端末 B は pull 済みでも画面が古いまま。ユーザーが pull-to-refresh するまで気付けない）。
  T4 の目的「Composition Root をローカルファーストに切替」が UI まで到達していない。
- 修正:
  - `SyncEngine.syncNow(reason:)` を追加（実行中サイクルがあれば待つ・多重起動は畳む awaitable な入口）。
    `runCycleNow` はこれに委譲（`meigicho/Packages/DataStore/Sources/DataStore/Sync/SyncEngine.swift:82-99`）。
  - `MeigichoApp.syncAndRefresh(reason:)` を追加し、**サイクル完了後に**
    `identityStore.load()` / `applicationStore.load()` を実行。launch / foreground / 手動再試行の
    3 経路すべてがこれを通る（`meigicho/App/MeigichoApp.swift:143,151,166,173-180`）。
  - 回帰テスト `testConcurrentSyncNowRunsSingleCycle`
    （`Tests/DataStoreTests/SyncEngineCollectionsTests.swift:197-213`）。

---

## 中 (Should Fix) — 申し送り

### M1. `SYNC_APPLY_FAILED` の恒久スタックがユーザーに見えない

`SyncEngine.drainOutbox()`（`SyncEngine.swift:131-176`）は rejected を `OutboxQueue.recordFailure` に
記録するだけで、サイクル自体は成功扱い（`.upToDate`）で終わる。ホームの同期バナーは `.failed` しか
出さない（`HomeView.swift:124-130`）ため、**永久に送れない行があっても画面上は「同期済み」**。

現実的な発生経路: Prisma `Tour @@unique([ownerId, name])`（`apps/api/prisma/schema.prisma:161`）。
2 端末が同名ツアーを別 id で作ると片方の push が P2002 → `SYNC_APPLY_FAILED`
（`apps/api/src/sync/sync.service.ts:155,271-288`）となり、以後毎サイクル失敗し続ける。
`syncStatusStore.pendingCount` は算出済みなので、`pendingCount > 0` かつ失敗が続く場合の 1 行表示を
T5 で足すべき。

### M2. `OutboxEntry.nextRetryAt` / `attemptCount` が誰にも読まれない

`OutboxQueue.recordFailure` は指数バックオフを書き込む（`OutboxQueue.swift:36-50`）が、
`drainOutbox` は `fetchPending`（`syncState != .synced`）だけで対象を決めるため、
バックオフは一切効かず毎サイクル即再送する。Outbox テーブルは実質デコレーション。
T5 でどちらかに寄せる（バックオフを効かせる or Outbox を廃してフラグ一本化）。

### M3. `resetLocalStore()` と実行中サイクルの競合

ログアウト時に `syncEngine` のサイクルが走っていても停止・待機しない
（`AppEnvironment.swift:119-138`）。`.task(id:)` のキャンセルは actor 内の `Task {}` に伝播しない。
削除直後に遅れて到着した pull が行を書き戻す窓が残る。`syncEngine.cancelAndWait()` 相当を
T5 で足すのが望ましい。

### M4. `markSynced()` の `remoteUpdatedAt` はサーバー時刻ではない

`SyncableRecord.markSynced()`（`SyncableRecord.swift:27-30`）は `remoteUpdatedAt = recordUpdatedAt`
（= 端末時刻）を入れるが、サーバーの `updatedAt` は Prisma `@updatedAt`（`schema.prisma:113` 他）で
**サーバー時刻**。`rewindCursor`（`SyncEngine.swift:243-257`）はこの端末時刻を基準にカーソルを
戻すため、端末時計が進んでいると巻き戻し不足でサーバー確定値を取り逃す。
`SyncPushResult.serverTime` を採用するか、push 受理後に必ず 1 回無条件 pull する方が堅い。
（T2 由来の既存挙動。今回の contract 追加で影響範囲が広がった）

### M5. BE の `next_cursor` がコレクション横断の max で、ページングが取りこぼす

`apps/api/src/sync/sync.service.ts:56-92`: `has_more` は「どれか 1 コレクションが 500 件に達した」で
立つ一方、`next_cursor` は**全コレクションの max(updatedAt)**。打ち切られたコレクションの残りが
カーソルの向こう側に飛び、`SyncEngine.pullAll()`（`SyncEngine.swift:178-195`）の
`while hasMore` ループでも回収できない。BE 側の既存不具合で T3/T4 の差分ではないが、
初回フルシンクで 500 件超になる利用者では実害が出る。別チケット化を推奨。

---

## 軽微 / 提案

- **L1** `.offline` がホームに何も出さない（`HomeView.swift:124`）。`plan.md` 手動確認 4 の
  「同期できていません」は失敗時のみを想定しているが、オフライン継続 + 未送信ありは伝えたい。
- **L2** `SwiftDataApplicationRepository.listPage`（`SwiftDataApplicationRepository.swift:21-52`）は
  全件 fetch してからメモリでカーソル絞り込み・`prefix`。件数が増えると O(n)。
  `FetchDescriptor.fetchLimit` へ寄せられる。
- **L3** `AppEnvironment.fallbackInMemoryContainer()` の `try!`（`AppEnvironment.swift:140-144`）。
  コメントで正当化済みだが、ここで落ちると原因が追えない。`fatalError` に理由を添える方が親切。
- **L4** `SyncEngine.pullAll` の `guardCounter < 20`（`SyncEngine.swift:180-183`）は
  マジックナンバー。定数化 + 上限到達時のログ/ステータスがあると調査しやすい。

---

## 良かった点

- **AC-SY-05 が構造で守られている**。`Features/Package.swift` の依存は Core/DesignSystem/Domain のみで
  `DataStore` / `Network` は入らない。同期状態は `Domain.SyncStatusStore`、アクションだけ
  `SyncActionBridge`（`Features/Home/SyncActionBridge.swift`）で Composition Root から注入という分離が明快。
- **API 契約 3 層の整合が正確**。`sync-serialize.ts` / `sync-payload.mapper.ts` と
  `*Record+SyncPayload.swift` を突き合わせた結果、6 コレクション全フィールドが一致。
  特に「applications は `tour_id` を持たない（event 経由）」という契約
  （`schema.prisma:184-211` に `tourId` 無し）を iOS 側が正しく踏襲し、
  `ApplicationRecord.swift:5-6` と `toDomain(tourID:)` で明示している（IOS-2 回避）。
- **`SyncField` / `SyncPayloadBuilder`（`SyncableRecord.swift:56-114`）が黙殺フォールバックを避けている**。
  型不一致は `nil`、`nil` は必ず `.null` で送る（undefined と区別する BE の
  `parseOptionalIso` 実装と整合）。BE-2 / IOS-2 の予防として良い設計。
- **companions の上限 3 件・`identity_id` 重複禁止・position 連番振り直しが
  `normalizeCompanions`（`SwiftDataApplicationRepository.swift:264-283`）で BE と同じ規則で実装**され、
  ローカル即時書き込みでもサーバーと同じ結果になる。
- **テストが AC に紐づいている**。`SyncEngineCollectionsTests` の 4 本が
  AC-SY-01 / 03 / 04 に明示対応。LWW reject テストが「サーバー値の方が古くても取り込む」という
  非自明な仕様を固定している点が良い。

---

## 手動確認手順（実機 2 端末 / T4 の受入）

1. 端末 A で名義追加 → 端末 B をフォアグラウンド復帰 → **画面をリロードせずに**名義が現れる（修正 2）
2. 機内モードで申込を作成 → **アプリを強制終了して再起動**（オフラインのまま）→ 申込が残っている（修正 1・AC-SY-04）
3. 2 の状態でオンラインに戻す → フォアグラウンド復帰で push され、pendingCount が 0 になる
4. 明示ログアウト → 一覧が空になり、別アカウントでログインしても前ユーザーのデータが出ない
5. サーバーを落として起動 → ホームに 1 行だけエラーバー（アラート・モーダルは出ない / AC-SY-06）

---

# T5 レビュー（デバウンス / scenePhase / 低データモード / BGAppRefreshTask）

対象: `work/ios-sync-t5` の `main...HEAD`（実装コミット `3bf1579`）+ 本レビューでの修正コミット。
レビュー日: 2026-08-09。

## レビュー結果サマリ

- 重大: 2 件（**いずれも本レビュー内で修正済み。再検証で重大ゼロを確認**）
- 中: 3 件
- 軽微/提案: 4 件

## 重大 (Must Fix) — 修正済み

### 1. ローカル `Network` パッケージが Apple の `Network.framework` を隠し、増分ビルドが壊れる

`meigicho/Packages/DataStore/Sources/DataStore/Sync/Reachability.swift:2` の `import Network`。

実装者は「`DataStore` は SPM の `Network` パッケージに依存していないので衝突しない。クリーンビルドで確認済み」
と申告していたが、**これは誤り**。Xcode 統合 SPM ではパッケージのモジュール検索パス（`-I <BuiltProducts>`）が
ワークスペース内の全ターゲットで共有されるため、`Package.swift` の依存に無くても解決されうる。

再現（レビューで実施）:

```
rm -rf /tmp/dd && xcodebuild ... -derivedDataPath /tmp/dd build   → BUILD SUCCEEDED
touch meigicho/Packages/DataStore/Sources/DataStore/Sync/Reachability.swift
xcodebuild ... -derivedDataPath /tmp/dd build                      → BUILD FAILED
  error: cannot find type 'NWPathMonitor' in scope   (Reachability.swift:19 ほか 8 件)
```

つまり **1 回目は通るが 2 回目から壊れる**。実装者が見た
`warning: 'DataStore' is missing a dependency on 'Network'` はまさにこの赤信号だった。
「壊れるならコンパイルエラーという大きな音で落ちる」という主張は結果的に当たっているが、
落ちるのは*正しい方*ではなく **Apple のフレームワークを使いたい側**であり、
CI・他開発者の 2 回目のビルドが理由不明で落ちる状態は出荷不可。

さらに `project.yml:26-27` に「自作 `Network` パッケージと Apple の `Network.framework` が衝突するため
RevenueCat を一時無効化中」というコメントが既にあり、**このリポジトリでは同じ衝突が過去に一度実害を出している**。

**修正**: ローカルパッケージを `Network` → `Networking` に改名（モジュール名・ディレクトリ・テストターゲット・
`project.yml`・`App` 側 2 ファイルの `import`）。`xcodegen generate` 済み。
クリーン／増分の両方で BUILD SUCCEEDED、警告も消滅。副次的に RevenueCat 再有効化の障害も除去した。
`feedback_review_patterns.md` に **IOS-12** として追記。

### 2. `BGTaskScheduler` の launch handler で `MainActor.assumeIsolated` → 実行時クラッシュ

`meigicho/App/BackgroundSyncScheduler.swift:40-51`。

```swift
using: nil // メインキュー   ← コメントが事実と異なる
) { task in
    MainActor.assumeIsolated { ... }
}
```

`BGTaskScheduler.h` の doc comment は
`queue: A queue for executing the task. Pass nil to use a default background queue.`
＝ **`nil` はメインキューではなくデフォルトのバックグラウンドキュー**。
その上で `MainActor.assumeIsolated` を呼ぶと Swift 6 のランタイムが
`Incorrect actor executor assumption` でトラップし、**バックグラウンド起動のたびにアプリが即死**する。
シミュレータでもビルドでも再現せず、実機のバックグラウンド起動でのみ出るため最悪の見つかり方をする。

**修正**: `using: DispatchQueue.main` を明示（`BackgroundSyncScheduler.swift:40-46`）。
`feedback_review_patterns.md` に **IOS-11** として追記。

## 中 (Should Fix)

### 3. `Reachability.start()` の初期値が `monitor.currentPath` 依存で、起動同期を空振りさせうる — 修正済み

`Reachability.swift`。`monitor.start(queue:)` は非同期で、直後の `currentPath` は
まだ既定値（`.unsatisfied`）を返しうる。`MeigichoApp.swift:161-162` は
`await reachability.start()` の**直後**に `syncAndRefresh(reason: .launch)` を呼ぶため、
ここで `isOnline = false` が入ると `SyncEngine.runCycle`（`SyncEngine.swift:106-111`）が
`.offline` を publish して即 return し、**前面復帰まで起動同期が走らない**。
`pathUpdateHandler` が後から正しい値を入れても、その周回はもう終わっている。

**修正**: 初期シードは `currentPath.status == .satisfied` のときだけ採用し、
それ以外は従来どおり `SCNetworkReachability` のワンショット（`checkOnline()`）で裏を取るようにした。

### 4. 低データモード時にユーザーへ何も伝わらない（T4 由来・スコープ外だが T5 で実効化した）

`SyncEngine.swift:110-112` は `constrained && reason != .manual` で**無言 return** する。
T4 までは `isConstrained` が常に `false` だったので死んでいたが、T5 で実値が入ったことで
初めてこの経路が生きた。結果、低データモードのユーザーには
「同期されないが状態表示も変わらない（最後の `.upToDate` のまま）」という見え方になる。
`docs/05` §5 は「低データモードでは自動同期を止め**手動のみ**」としており、
手動できることが伝わらないと仕様の意図を満たさない。
`SyncStatus` に低データモード用の表示を足すか、少なくとも `.idle` に落として
ホームの「手動同期」導線を出すことを次タスクで検討されたい（今回は `SyncEngine` 変更禁止指示のため未対応）。

### 5. `BGAppRefreshTask` が `.launch` トリガを流用している

`BackgroundSyncScheduler.swift:179`。`SyncTrigger` に `.background` を足さない制約は理解するが、
`docs/05` のトリガ表では起動と背景は別行であり、将来トリガ別の扱い
（例: 背景では pull のみ・バックオフ短縮）を入れるときに区別できない。
`SyncTrigger.background` の追加は T6 以降のバックログに積むことを推奨。

## 軽微 / 提案

6. `BackgroundSyncScheduler.runningTask`（`:127`, `:180`, `:196`）は代入と nil 化だけで読まれておらず、
   実質デッドフィールド。2 本目の BG タスクが来たら上書きされるだけで排他にもなっていない。
   削るか、`guard runningTask == nil` の排他に使うかどちらかにするのが明快。
7. 正常完了パスは同期の成否に関わらず `gate.complete(success: true)`（`:197`）。
   `SyncEngine` は失敗を throw せず status に載せるだけなので現状は取りようがないが、
   OS の学習（success 率でスケジュール頻度が変わる）には嘘を伝えている。
8. `Debouncer.call`（`Debouncer.swift:26-38`）は、直前のタスクが既に `operation()` に入っていると
   `cancel()` で止まらず 2 回実行されうる。実害は `SyncEngine.syncNow` 側の
   `currentTask` 直列化（`SyncEngine.swift:140-149`）で吸収されるので現状は問題ないが、
   Debouncer 単体の契約としては「最後の 1 回だけ」ではない点をコメントに書いておくと安全。
   また `pending` は完了後も保持され続ける（実害なし）。
9. UI テスト構成（`syncEngine == nil`）では `register()` が早期 return するため、
   `BGTaskSchedulerPermittedIdentifiers` に載っている識別子にハンドラが無い状態になる。
   `submit` しないので実害は無いが、Apple の建前（「plist の全識別子にハンドラを登録せよ」）とはズレる。

## 良かった点

- **`onWrite` の網羅性が完全**。`grep "context.save()"` の結果 11 箇所（identity 3 / membership 3 /
  catalog 2 / application 3、残り 2 件は `SyncEngine` 自身）すべてに `onWrite.didWrite()` が付いており、
  読み取り経路には `save()` が無い。`LocalWriteObserverTests.swift` が
  「読み取りでは発火しない」「失敗した書き込みでは発火しない」まで固定している（IOS-3 の予防として良い）。
- **IOS-5 を崩していない**。Repository は `SyncEngine` を知らず、`LocalWriteObserver` という
  値型の細い口だけを受け取り、デバウンスと同期起動は Composition Root（`AppEnvironment.swift:113-131`）が担う。
  `DataStore/Package.swift` の依存も `Core` / `Domain` のままで逆流なし。
- **IOS-6 と整合した停止条件**。`editSyncDebouncer.cancel()` は `resetLocalStore()` の中にあり、
  それを呼ぶのは `resetLocalStoreIfSessionCleared()`（`AppEnvironment.swift:222-224`）＝
  **Keychain の refresh token が実際に消えているときだけ**。オフライン起動の `.signedOut` では
  デバウンスも消えず未送信の編集も残る。指示に無かった `currentRefreshToken() != nil` ガード
  （`AppEnvironment.swift:121`）も同じ判定軸を使っており、オフライン（トークンあり・ネットだけ無い）では
  同期を止めない。安全弁として妥当。
- **`TaskCompletionGate` は目的を果たしている**。`NSLock` + `isCompleted` で
  expirationHandler / watchdog / 正常完了の三者が競合しても `setTaskCompleted` は高々 1 回。
  25 秒の自衛 watchdog で「未呼び出し」側も塞いでいる。
- **`SyncEngine.runCycle` は無改修**（`git diff` で `SyncEngine.swift` に差分なしを確認）。指示どおり。
- **`project.yml` → `xcodegen generate` → `Info.plist` / `pbxproj` の反映が済んでいる**（IOS-8 回避）。
  `App/Info.plist` に `UIBackgroundModes: [fetch]` と `BGTaskSchedulerPermittedIdentifiers`、
  `pbxproj` に `Core` プロダクト依存と `BackgroundSyncScheduler.swift` が入っていることを確認。
  plist の識別子と `BackgroundSyncScheduler.taskIdentifier` の文字列も一致。

## 検証（本レビュー実施分）

| コマンド | 結果 |
|---|---|
| `cd meigicho/Packages/Core && swift test` | 20 tests / 0 failures |
| `cd meigicho/Packages/DataStore && swift test` | 22 tests / 0 failures |
| `cd meigicho/Packages/Networking && swift test` | 165 tests / 0 failures（改名後） |
| `cd meigicho/Packages/Domain && swift test` | 207 tests / 0 failures |
| `xcodebuild ... build`（クリーン DerivedData） | **BUILD SUCCEEDED**（警告 `missing a dependency on 'Network'` 消滅） |
| `touch Reachability.swift` → 同 DerivedData で再ビルド | **BUILD SUCCEEDED**（修正前は BUILD FAILED） |

`Packages/Features` の `swift build` は macOS プラットフォーム宣言が無いため単体では失敗するが、
これは本差分と無関係の既存事情（iOS アプリビルドでは成功）。

## 手動確認手順（T5 の受入 / 実機推奨）

1. 名義名を連続で打鍵 → 打鍵中は同期が走らず、**手が止まって 3 秒後に 1 回だけ**同期が走る
2. ログアウト状態でローカル編集 → 同期エラーバーが出ない（`currentRefreshToken` ガード）
3. 設定 > モバイル通信 > 低データモード ON → 自動同期が止まり、手動同期だけ効く
4. アプリをバックグラウンドへ → `BGTaskScheduler` に予約が入る
   （デバッグは `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"jp.meigicho.app.sync-refresh"]`）。
   **修正 2 の前はこの時点でクラッシュしていたはず**なので、実機で必ず 1 回確認すること
5. 機内モードで起動 → 起動同期がオフライン表示になり、解除後の前面復帰で追いつく（修正 3 の確認）
