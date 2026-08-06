# ios-sync-engine — Plan

## 実装順（直列）

| Task | 内容 | 検証 | 依存 |
|---|---|---|---|
| **T0** ✅ | Network: Sync DTO + `RemoteSyncRepository` / Domain: `SyncRepository`・`LWWResolver` + テスト | Domain/Network `swift test` | — |
| **T1** ✅ | DataStore パッケージ新設（XcodeGen）+ SchemaV1（identities 最小）+ `SwiftDataIdentityRepository` | ビルド + Domain モック維持 | T0 |
| **T2** ✅ | OutboxEntry + SyncEngine actor（identities only: push→pull）+ Reachability | LWW / Outbox 単体 + 手動 2 端末メモ | T1 |
| **T3** | memberships / tours / events / applications / companions を順に追加 | コレクションごとの pull/push テスト | T2 |
| **T4** | Composition Root 切替（local-first）+ 同期状態 UI（ホーム 1 行） | `xcodebuild` + 手動手順 | T3 |
| **T5** | デバウンス・scenePhase・低データモード骨格 | 手動 | T4 |

## T0 詳細（最初に着手）

1. `Domain/Sync/LWWResolver.swift` + `LWWResolverTests`
2. `Domain/Sync/SyncTypes.swift`（collections・cursor・mutation・pull/push 結果）
3. `Domain/Repositories` に `SyncRepository`
4. `Network/DTO/SyncDTO.swift` + `RemoteSyncRepository`
5. `InMemorySyncRepository`（Preview）
6. Network DTO テスト（snake_case / has_more / rejected）

## 手動確認（T2 以降）

1. 端末 A で名義追加 → オンライン → 端末 B pull で見える  
2. 機内モードで編集 → 再接続で push  
3. 両端末で同一名義を編集 → LWW で新しい方が残る  
4. 同期失敗時、ホームに「同期できていません」1 行（アラートなし）

## ファイル所有

- T0: `meigicho/Packages/Domain`, `Network`（Sync 新規のみ）
- T1〜: `meigicho/Packages/DataStore`（新設）、`project.yml`
- T4: `App/`, `Features/Home`（同期バナーのみ）

`ApiClient` / 既存 Remote CRUD は T4 まで読み取り優先。切替は Composition Root のみ。
