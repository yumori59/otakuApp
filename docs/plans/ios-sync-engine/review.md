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
