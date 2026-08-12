# application-edit — Workflow Plan

`requirements.md` の受入基準を実装タスクへ分解する。実装着手前に Q1〜Q8（`questions-requirements.md`）の回答で差分がないか確認すること。

## 0. 現状把握（ギャップ分析）

| 層 | 既にあるもの | 欠けているもの |
|---|---|---|
| DB | `applications` / `application_companions` / `events` / `tours`（ソフトデリート・`updated_at`）| なし（**スキーマ変更なし**） |
| BE REST | `PATCH /v1/applications/:id`（`applications.controller.ts:49`、`update-application.use-case.ts`、companions 全置換 = `applications.service.ts:244-331`）/ `PATCH /v1/tours/:id`（`tours.controller.ts:42`）/ `PATCH /v1/events/:id`（`events.controller.ts:38`） | なし（**追加実装なし**）。ただし `event_id`/`tour_id` 付け替えは 400（`update-application.dto.ts:27-31`） |
| BE 同期 | `POST /v1/sync/push` が 4 コレクションの upsert を受ける（`sync-collections.ts:5-8`、`sync.service.ts:215-268`）。`events.tour_id` の差し替えも受理される | なし（R-1/R-2 は既知リスクとして記録のみ） |
| iOS Domain | `ApplicationPatch.companions: Patchable<[Companion]>`（`Patches.swift:41`）、`TourPatch` / `EventPatch`（`Patches.swift:46-60`）、`CatalogRepository.updateTour/updateEvent`（`Repositories.swift:66-67`） | `EventPatch` に `tourID` が無い（付け替え不可 = R-3）。`ApplicationStore` に companions を含む汎用 update が無い（あるのは `updateApplicationStatus:362` と `updateApplicationSeat:369` だけ）。`updateTour`/`updateEvent` の**呼び出し元がゼロ**（実装済み未配線） |
| iOS DataStore | `SwiftDataApplicationRepository.update` が companions 全置換込みで実装済み（`:96-139`、`replaceCompanions:225`）。tour find-or-create（`:167`）/ event upsert（`:196`）は `create` から呼ばれる private | 上記 2 つを編集経路から使う口が無い |
| iOS Features | 追加フォーム `AddApplicationView.swift`（12 項目）。詳細 `ApplicationDetailView.swift`（同行者は表示のみ `:122-141`、書き込みは status `:99` と seat `:153` のみ） | 編集画面そのもの。`AppSheet` に編集ケースが無い（`AppRoute.swift:18-39`） |

**結論**: BE は追加実装ゼロ、DB 変更ゼロ。**不足は iOS の縦串（Domain の差分計算 → Repository の口 → 編集 UI）だけ**。ただし「ツアー付け替え」だけは既存 API で表現できない（R-3）ため Domain/DataStore に最小の拡張が要る。

## 1. 設計判断

### D-1 書き込み経路はローカル SSoT + 同期 push（REST PATCH は使わない）

`AppEnvironment.swift:128-131` が本番構成で `SwiftData*Repository` を注入しており、UI からの書き込みは SwiftData → outbox → `SyncEngine` → `POST /v1/sync/push`。編集もこの経路に乗せる。

- 却下: `RemoteApplicationRepository`（`PATCH /v1/applications/:id`）を直接叩く。ローカルが SSoT なので二重書き込みになり、オフライン編集（FR-AE-10）が壊れる。
- 帰結: BE の PATCH 契約は**変更も利用もしない**。将来 REST 経路に戻す場合、`tour_id` 付け替えは 400 なので設計をやり直す必要がある（C-1）。

### D-2 差分計算は `Domain` の純粋関数に置く

iOS の機械ゲートはビルド成功のみ（`.claude/rules/05-harness.md`）だが、`Packages/Domain` と `Packages/DataStore` には XCTest が既にある（`Domain/Tests/DomainTests/*`）。同行者の id 保持・正規化・「変更なしなら送らない」判定は**純粋関数に切り出して XCTest で Red→Green** にする。

- 却下: View の `save()` 内で `ApplicationPatch` を組み立てる。テスト不能で、AC-AE-03/04/05/06 が手動確認だけになる。

### D-3 ツアー付け替え + 公演更新 + 申込更新は 1 メソッド 1 セーブ

`ApplicationRepository` に「申込 + そのツアー/公演」をまとめて更新する口を足す。SwiftData 実装は `create` の `findOrCreateTour`（`:167`）/ `upsertEvent`（`:196`）/ `replaceCompanions`（`:225`）を**そのまま再利用**する。

- 却下 a: `EventPatch.tourID` を足して `CatalogRepository.updateEvent` で付け替える。tour の find-or-create 手段が `CatalogRepository` に無い（C-3）ため、Store が「まず tour を作る」方法を持てない。
- 却下 b: `catalogRepository.updateTour` → `updateEvent` → `applicationRepository.update` の 3 回呼び。SwiftData の `save()` が 3 回に割れ、途中失敗で公演だけ書き換わった中途半端な状態が残る。
- protocol への追加はデフォルト実装（`AppError.validation` で「この経路は未対応」を明示して throw）を持たせ、未使用の `RemoteApplicationRepository` を触らずに済ませる。`InMemoryApplicationRepository`（UI テスト用）は素直に実装する。**黙ってフォールバックしない**（BE-2 の iOS 版）。

### D-4 フォームは統合し、リファクタと機能追加を分ける

`ApplicationFormView(mode:)` に統合（Q8-A）。ただし
1. 振る舞い不変の抽出（T4）
2. edit モード追加（T5）
に分割し、T4 単体で「追加フローが従来どおり」をレビュー・確認できるようにする。

- 却下: `EditApplicationView` を別実装。12 フィールド + 同行者 3 系統が二重管理になり必ずドリフトする。

### D-5 編集保存は楽観更新しない

`ApplicationStore.applyOptimistic`（`:377`）は 1 フィールドの巻き戻し向け。編集は申込 + 公演 + ツアーにまたがるため、失敗時の巻き戻しが「後付け undo」になる（IOS-13 で焼かれたパターン）。`addApplication`（`:341-359`）と同じく **保存中はスピナー、成功でリポジトリの戻り値を反映して dismiss、失敗はフォームを開いたままエラーバー** にする。

## 2. API 契約

**新規エンドポイントなし。既存契約の変更なし。** 本機能が使う経路を確定させる（実装者はこの表を正とする）。

### 使う経路: `POST /v1/sync/push`（既存・変更なし）

```jsonc
{
  "mutations": [
    { "collection": "tours",                  "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { /* 下表 */ } },
    { "collection": "events",                 "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { ... } },
    { "collection": "applications",           "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { ... } },
    { "collection": "application_companions", "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { ... } }
  ]
}
```

payload の形は既存の `syncPayload()` 実装が正（`ApplicationRecord+SyncPayload.swift`）。編集で新たに使われる組み合わせは以下だけで、**キーの追加・改名は無い**。

| collection | 編集で変わりうるキー |
|---|---|
| `tours` | `name`（付け替え先を新規作成する場合のみ・新 id）/ `artist_name_raw` |
| `events` | `tour_id`（付け替え時）/ `name` / `venue_name_raw` / `event_date` |
| `applications` | `rep_identity_id` / `applied_on` / `result_on` / `status` / `seat_raw` / `note` |
| `application_companions` | `identity_id` / `display_name` / `position` / `deleted_at`（行削除時） |

- `status` の enum は `draft` / `applied` / `won` / `lost` / `cancelled`（`apps/api/src/applications/dto/application-status.ts`）。UI は `cancelled` を出さない（R3-1）。**未知値を送らない・落とさない**（BE-2）
- `deleted_at` は同行者を外したときのみ非 null。行の物理削除は行わない
- `rep_membership_id` は常に送らない（C-4）

### 使わない経路（契約は現状維持）

| エンドポイント | 状態 |
|---|---|
| `PATCH /v1/applications/:id` | 既存のまま。`event_id`/`tour_id` は 400 |
| `PATCH /v1/tours/:id` | 既存のまま。name 衝突は 409 |
| `PATCH /v1/events/:id` | 既存のまま。`tour_id` は 400 |

## 3. タスク分解

担当は `.claude/rules/02-agents.md` に従う。**BE の製品コード変更は無い**（T7 は調査のみ）。

| # | タスク | 層 / 主な対象 | 担当 | 依存 |
|---|---|---|---|---|
| T1 | 編集の差分計算を純粋関数として追加（`ApplicationEditForm` 相当 + `ApplicationPatch` / `TourDraft?` / `EventDraft?` の組み立て）。同行者 id 保持・正規化・「変更なしは送らない」判定。**XCTest 先行（Red→Green）** | `Packages/Domain/Sources/Domain/Models` + `Domain/Tests` | swift-developer | — |
| T2 | `ApplicationRepository` に scope 付き update（申込 + tour/event）を追加（デフォルト実装は明示 throw）。`InMemoryApplicationRepository` を実装。`ApplicationStore.updateApplication(...)` を追加し、戻り値で `applications` / `tours` / `events` を整合（`reconcileCatalog:459` と同じ考え方） | `Domain/Repositories/Repositories.swift`・`Domain/Stores/ApplicationStore.swift` | swift-developer | T1 |
| T3 | `SwiftDataApplicationRepository` に scope 付き update を実装（`findOrCreateTour:167` / `upsertEvent:196` / `replaceCompanions:225` を再利用、outbox は既存の `OutboxQueue.enqueue` で 4 コレクション分）。DataStore テスト追加 | `Packages/DataStore` | swift-developer | T2 |
| T4 | `AddApplicationView` から `ApplicationFormView` を抽出（**振る舞い不変**のリファクタ。追加フローの見た目・保存挙動を変えない） | `Packages/Features/Sources/Features/Forms` | swift-developer | — |
| T5 | edit モード追加 + 配線: `AppSheet.editApplication(id:)`（`AppRoute.swift`）/ `SheetContentView`（`:15-16` の隣）/ `ApplicationDetailView` に「編集」ツールバー / 波及注意文（FR-AE-7・FR-AE-8） | `Packages/Features` | swift-developer | T3・T4 |
| T6 | docs 追従: `docs/05-ios-client.md`（画面追加・編集フロー）、`docs/01-product-overview.md`（R2 系に「申込の編集」を追加要件として明記）、`docs/09-roadmap.md`（0-11 の拡張である旨） | `docs/` | swift-developer or メイン | — |
| T7 | （任意・調査）R-1 の再現確認: `sync.push` で unique 違反が起きたとき後続 mutation が巻き添えになるか。`sync.service.spec.ts` で再現テストを書き、巻き添えが起きるなら別計画に切り出す。**製品コードは変更しない** | `apps/api/src/sync` | nest-developer | — |

### 並列実行可能なタスク

```
[T1] ‖ [T4] ‖ [T6] ‖ [T7]        ← 互いにファイルが重ならない
        ↓
      [T2]                        ← Repositories.swift / ApplicationStore.swift（単独占有）
        ↓
      [T3]                        ← DataStore（単独占有）
        ↓
      [T5]                        ← Features（T4 と同一ファイルなので直列必須）
```

- **同一ファイルを 2 人に触らせない**: `Forms/*`（T4→T5 直列）、`Repositories.swift` と `ApplicationStore.swift`（T2 のみ）
- BE と iOS の並列は可（契約は §2 で確定済み）。ただし T7 は調査で製品コードを触らない

## 4. 受入基準 → テストケース

| AC-ID | テスト | 種別 / 置き場所 |
|---|---|---|
| AC-AE-03 | 同行者削除で残りが 0 起点連番になる | XCTest `Domain/Tests`（T1） |
| AC-AE-04 | 表示名だけ変更 → companion `id` 不変 | XCTest `Domain/Tests`（T1） |
| AC-AE-05 | 同行者無変更 → `patch.companions == .unchanged` | XCTest `Domain/Tests`（T1） |
| AC-AE-06 | 代表者と同一 / 重複名義 / 4 人目が落ちる | XCTest `Domain/Tests`（T1） |
| AC-AE-09 | ツアー名を既存名にすると tour が増えず event の `tourID` が既存 tour を指す | XCTest `DataStore/Tests`（T3） |
| AC-AE-10 | 未使用のツアー名 → tour が 1 件だけ増え、他申込の tour は不変 | XCTest `DataStore/Tests`（T3） |
| AC-AE-02 | 同行者追加で `fetchActive` が 1 件増え、outbox に `applicationCompanions` が積まれる | XCTest `DataStore/Tests`（T3） |
| AC-AE-13 | 削除済み申込の編集は `.notFound`、新規行を作らない | XCTest `DataStore/Tests`（T3） |
| AC-AE-01 / 07 / 08 / 11 / 12 / 14 / 15 | 手動確認（§5） | — |

**Red 先行の対象**: T1・T3。実装前に失敗するテストを書く。T2 は Store の薄い委譲だが、`updateApplication` が repository の戻り値で `tours`/`events` を整合させる部分は Store テスト（`ApplicationStoreNetworkTests.swift` の Fake パターン）で 1 本押さえる。

## 5. 手動確認手順（iOS）

前提: `make up` でローカル API、シミュレータでサインイン済み、申込が 2 件以上（うち 2 件は同一公演）。

1. **AC-AE-01** 申込詳細 → 右上「編集」→ 全項目に現在値が入っている
2. **AC-AE-02/03** 同行者を 1 人追加 → 保存 → 詳細に反映。再度開いて 1 人削除 → 残りの並びが崩れない
3. **AC-AE-07/08** 同一公演を持つ申込を開き会場名を変更 → 保存前に「他 N 件にも反映されます」が出る → 保存後、もう 1 件の詳細/一覧の会場名も変わる
4. **AC-AE-09** ツアー名を既存の別ツアー名に変更 → ツアー表でその公演が既存ツアーの下に移り、元ツアーの他の公演は動かない
5. **AC-AE-11** 機内モードで編集・保存 → 反映される。オンライン復帰 → 同期バナーが消え、`psql` か別端末でサーバー反映を確認
6. **AC-AE-12** API を落とした状態ではなく**バリデーションで落ちる入力**（公演名を空にする等）で保存 → 画面が閉じずエラーが出る
7. **AC-AE-14** 詳細画面のステータス 3 ボタンと座席インライン編集が従来どおり動く
8. **AC-AE-15**（回帰）申込を新規追加 → 従来どおり作成でき、既存ツアー名を入れたときにツアーが増えない

## 6. 検証ゲート

```bash
# iOS ビルド（必須）
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build

# パッケージテスト（T1/T2/T3 の完了ゲート）
swift test --package-path meigicho/Packages/Domain
swift test --package-path meigicho/Packages/DataStore

# BE（T7 のみ。製品コード変更が無くても回帰確認として実行）
cd apps/api && npx tsc --noEmit && npm test -- --passWithNoTests && npm run build
```

`project.yml` を触った場合は `xcodegen generate` を忘れない（IOS-8）。

## 7. 実装時に踏みやすい罠（`feedback_review_patterns.md` から該当分）

| # | 本機能での具体形 |
|---|---|
| IOS-1 / IOS-3 | 編集画面を作って `AppSheet` / 詳細画面ツールバーへの配線を忘れる。`CatalogRepository.updateTour/updateEvent` が**既に実装済みで呼び出し元ゼロ**という前例がある（死にコードを手本にしない） |
| IOS-2 | 同期 payload のキー（`tour_id` / `position` / `deleted_at`）を編集経路で書き漏らす |
| IOS-5 | `Features` から `DataStore` を import しない。編集画面が触るのは `ApplicationStore` まで |
| IOS-13 | 保存失敗時の「後付け undo」を書かない（D-5） |
| BE-2 | `status` の未知値を黙って `applied` に落とさない |
| BE-4 | 編集対象の所有者確認はローカルでも省かない（`assertIdentityOwned` 相当を companions にも通す = 既存 `update:124-132` の踏襲） |

## 8. 委譲プロンプト案（オーケストレーター向け）

いずれも冒頭に「まず `.claude/skills/implementing-robustly/SKILL.md` を読み従う」を入れる。

- **T1 → swift-developer**: 目的（申込編集の差分計算を純粋関数化）/ 対象（`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain`）/ 入出力の型（現在の `ApplicationEntry` + `Tour` + `EventEntity` + フォーム入力 → `ApplicationPatch` と `TourDraft?` / `EventDraft?`）/ 既存例（`ApplicationStore.normalizedCompanions:418`）/ **XCTest を先に落としてから実装** / 完了条件（`swift test --package-path .../Domain`）/ 報告（①変更 ②検証結果 ③残課題、file:line）
- **T3 → swift-developer**: 対象（`meigicho/Packages/DataStore`）/ 既存例（`SwiftDataApplicationRepository.create:59` と `update:96`）/ 制約（新しい find-or-create を書かず既存 private を再利用・outbox は 4 コレクション分積む）/ 完了条件（DataStore テスト）
- **T5 → swift-developer**: 契約として §2 の payload 表と FR-AE-7/8 の文言要件を書き写す / スコープ外（削除 UI・`round_name`/`ticket_count`/`price_yen`）を明記
- **T7 → nest-developer**: 対象（`apps/api/src/sync`）/ 目的（R-1 の再現有無の確定）/ **製品コードを変更しない・テストのみ** / 報告に「巻き添えが起きるか / 起きるならどの mutation まで」を明記

レビューは実装完了後に**別セッションで** `code-reviewer` を呼び、結果を `docs/plans/application-edit/review.md` に保存する（`.claude/rules/04-review.md`）。
