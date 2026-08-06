# ios-sync-engine — Requirements

**日付**: 2026-08-05  
**参照**: `docs/04-api.md` §4 / `docs/05-ios-client.md` §5 / `docs/09-roadmap.md` 1-3 / BE `apps/api/src/sync/`

## 1. 背景・ギャップ

| 層 | 状態 |
|---|---|
| BE `POST /v1/sync/pull` `push` | ✅ 実装済み（LWW・ソフトデリート・名義上限） |
| iOS Network Sync DTO / Repository | ❌ |
| iOS DataStore（SwiftData） | ❌ パッケージ未作成 |
| iOS SyncEngine / Outbox | ❌ |
| 現状の CRUD | オンライン直叩き（`Remote*Repository` → メモリ Store） |

`docs/05` は **SwiftData がローカル SSoT**、SyncEngine actor、Outbox ポインタキューを正とする。現状はそれに未到達。

## 2. 目標（Phase 1 垂直スライス）

1. 起動・フォアグラウンドで **pull → ローカル反映**
2. 編集は **ローカル即時 + Outbox → push**（LWW）
3. ソフトデリート伝播（`deleted_at`）
4. 同期状態 UI（失敗・未送信のみ。成功は出さない）
5. コレクション: identities → memberships → tours/events/applications/companions（段階導入）

## 3. 非目標（本計画スコープ外）

- AdMob / 統計画面 UI
- CRDT・自動マージ UI
- BGAppRefresh の本番品質チューニング（骨格のみ）
- 共有リンク・billing の sync 対象化

## 4. 受入基準（抜粋）

| ID | 基準 |
|---|---|
| AC-SY-01 | `SyncRepository.pull` が docs/04 の JSON を Domain 値に写せる |
| AC-SY-02 | `LWWResolver` が remote newer / local newer / remote deleted を純関数で決定 |
| AC-SY-03 | Outbox ドレイン後に `push` し、`SYNC_LWW_REJECT` はローカルをサーバー値で上書き |
| AC-SY-04 | オフライン中の create/update/delete が再起動後も失われない |
| AC-SY-05 | Features は DataStore/Network を import しない |
| AC-SY-06 | 同期失敗はホームに 1 行表示のみ（モーダル禁止） |

## 5. 設計判断

| 判断 | 採用 | 却下 |
|---|---|---|
| ローカル永続 | SwiftData DataStore 新設（docs/05） | UserDefaults のみ（容量・クエリ不足） |
| 書き込み経路 | 段階移行: まず identities を local-first | 全コレクション同時切替（リスク大） |
| 契約 | 既存 `docs/04` §4 + BE 実装を正 | 新エンドポイント追加 |

## 6. 未決

**未決なし**（実装順とスライス境界は `plan.md`）。
