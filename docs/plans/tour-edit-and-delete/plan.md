# tour-edit-and-delete — Workflow Plan

`requirements.md` の受入基準を実装タスクへ分解する。着手前に `questions-requirements.md` の Q1〜Q7 の回答で差分がないか確認すること。

## 0. 現状把握（ギャップ分析）

| 層 | 既にあるもの | 欠けているもの |
|---|---|---|
| DB | `tours.deleted_at` / `@@unique([ownerId, name])`（`schema.prisma`） | なし（**スキーマ変更なし**） |
| BE REST | `PATCH /v1/tours/:id`（`tours.controller.ts:42-49`・同名は 409）/ `DELETE /v1/tours/:id`（`:51-55`・ソフトデリート・連鎖なし） | なし（**製品コードの追加実装なし**） |
| BE 同期 | `tours` は同期対象（`sync-collections.ts:5`）。payload は `name` / `artist_name_raw` / `deleted_at`（`sync-payload.mapper.ts` `case 'tours'`）。同名衝突は upsert 前に事前検出して個別 reject（`sync.service.ts:363-379`）。FK 検証は削除済み親を許容（`sync.service.ts:257-261`） | **tours の tombstone / 同名 reject の回帰テストがゼロ** |
| iOS Domain | `CatalogRepository.updateTour`（`Repositories.swift:66`）。`Tour` / `TourPatch` も完備 | `deleteTour` が protocol に無い。`ApplicationStore` に更新 / 削除メソッドが無い |
| iOS DataStore | `SwiftDataCatalogRepository.updateTour:44-54`（outbox `.tours` 込み・**呼び出し元ゼロ** = IOS-1）。`TourRecord.softDelete()` も実装済み。`SwiftDataApplicationRepository.delete:194-209` が「本体 + 子を 1 セーブで tombstone 化」の手本 | ツアー削除の連鎖。`EventRecord` の tourID 引き・`ApplicationRecord` の eventID 引きの fetch ヘルパ（`ApplicationCompanionRecord.fetchActive(applicationID:)` に相当するものが無い） |
| iOS Networking | `RemoteCatalogRepository.updateTour:35-42` | `deleteTour`（protocol 追加に伴い必要） |
| iOS Features | `TourGroupView`（`ApplicationListView.swift:304-453`）にヘッダー + 共有ボタン群（`actionButtons:378-393`）。`AppSheet.editApplication` / `SheetContentView` の分岐 | ツアー編集 / 削除の導線・編集シート（`TourFormView`）・`AppSheet.editTour` |

**結論**: DB 変更ゼロ・BE 製品コード変更ゼロ。**編集は Repository 層まで完成済み**で Store と UI だけが無く、**削除は protocol から無い**。

## 1. 設計判断

### D-1 導線はツアー表ヘッダー。ツアー専用画面は作らない

`TourGroupView` のヘッダーは既に「ツアー名 + 共有バッジ + 件数 + アクションボタン群」を持つ（`ApplicationListView.swift:338-393`）。ここに「編集」「削除」を並べる。

- 却下 a: `AppRoute.tour(UUID)` + `TourDetailView` + ツアー一覧画面の新設。ツアー表がすでにツアー詳細そのもの（表 + 集計 + 共有）であり、二重になる。Phase 0 の画面構成（`docs/09-roadmap.md:63` の 9 画面）も超える。
- 却下 b: 申込詳細に「このツアーを編集」を置く。申込詳細は既に「編集」「（delete-ui で）削除」を持ち、**同じ画面で 2 つのエンティティの削除ボタンが並ぶ**のは事故のもと。
- 帰結: `MainTabView` / `AppRoute` / `DeepLinkCoordinator` は触らない。追加するのは `AppSheet.editTour(id:)` だけ。

### D-2 編集は 2 項目の専用シート。申込フォームは流用しない

新規 `Forms/TourFormView.swift`（ツアー名 + アーティスト名 + 保存/キャンセル）。`AddMembershipView` と同じ「小さい単一目的シート」の形。

- 却下: `ApplicationFormView` の再利用。あれは 12 項目の申込フォームで、ツアー名欄の意味も違う（付け替え = `ApplicationEditPlanner.makeTourDraft:179-188` は**新 UUID を発行して 1 申込だけ移す**）。混ぜると「どちらのツアー名編集か」が実装からもユーザーからも読めなくなる。
- 保存ボタンの活性条件は「ツアー名が空でない」かつ「元の値と違う」（FR-TE-3 / FR-TE-7）。

### D-3 書き込み経路はローカル SSoT + 同期 push（REST PATCH / DELETE は使わない）

本番構成は `SwiftData*Repository` を注入する（`AppEnvironment.swift:130`）。`SwiftDataCatalogRepository.updateTour` は既に outbox に積む形になっている（`:52`）。削除も同じ経路に乗せる。

- 却下: `RemoteCatalogRepository` 経由で `PATCH` / `DELETE /v1/tours/:id` を直接叩く。ローカルが SSoT なので二重書き込みになり、オフライン編集 / 削除（FR-TE-8 / 16）が壊れる。`application-edit` D-1・`delete-ui` D-1 と同じ判断。
- 帰結: **BE の PATCH / DELETE 契約は変更も利用もしない**。実行経路は `POST /v1/sync/push` のみ（§2）。`RemoteCatalogRepository.deleteTour` は protocol 準拠のために実装するが本番では呼ばれない（既存 `RemoteApplicationRepository.updateScoped` と同じ立場）。

### D-4 同名リネームはローカルで事前に弾く（サーバーの reject に任せない）

保存前に `TourRecord` を name 完全一致で検索し（**`deletedAt` で絞らない**）、自分以外がヒットしたら `AppError.conflict` 相当で失敗させる。

- 根拠: サーバー側の判定は `sync.service.ts:367-379` で「`ownerId` + `name` 一致・id 違い」を `deletedAt` 無視で見る。ローカル判定をこれと**同じ条件**にしないと、UI 上は保存できたのに同期だけ永久に失敗する。
- 却下 a: サーバーの reject に任せる。`SyncEngine.failureMessage:139-147` は個人情報混入を避けるため生 message を出さない設計で、「1件の変更を同期できませんでした」としか表示できない。どのツアーが失敗したかユーザーに伝わらない。
- 却下 b: 論理削除済みを除いて判定する。サーバーとズレて非同期に失敗する（却下 a と同じ結末）。
- 却下 c: 同名へのマージ（Q5-B）。配下公演の付け替えと取り消し不能性が伴い、本計画の範囲を超える。
- 判定は `SwiftDataCatalogRepository.updateTour` の内部で行う（Store ではなく Repository）。**既存の `SwiftDataApplicationRepository.findOrCreateTour:219-222` が同じ「name 完全一致・deletedAt 無視」の検索をしている**ので、条件を 2 種類にしない。

### D-5 削除は配下（events → applications → companions）まで連鎖し、1 セーブで閉じる

`SwiftDataCatalogRepository.deleteTour(id:)` が同一 `ModelContext` / 同一 `save()` で
①tour を softDelete → ②そのツアーの未削除 events を softDelete → ③各 event の未削除 applications を softDelete → ④各 application の未削除 companions を softDelete → ⑤それぞれ outbox へ enqueue、までを行う。

- 手本: `SwiftDataApplicationRepository.delete:194-209`（本体 + companions を 1 セーブで tombstone 化）。
- 根拠（連鎖する理由）: `ApplicationStore.groupApplications:314-317` は `tour(for:)` が nil の申込を**黙って捨てる**。連鎖しないと「ツアー表から消えるのにリストと集計には残る」申込が生まれる。BE の `tours.remove:78-91` は連鎖しないが、iOS は REST DELETE を使わない（D-3）ため実効セマンティクスは iOS が決める。`delete-ui` D-2 の名義削除（BE は memberships に連鎖しないが iOS は連鎖させる）と同じ判断。
- 却下 a: 連鎖せず孤児申込を許す（Q3-B）。読み側（ツアー表・リスト・ホーム集計・名義詳細）すべてに「ツアーが無い申込」の表示規則を足す必要があり、消し忘れが静かなバグになる。
- 却下 b: 申込のあるツアーは削除不可（Q3-C）。ツアー表に出るツアーは定義上必ず申込を持つ（`groupApplications` は申込からグループを作る）ので、ボタンが常に無効になる。
- 却下 c: Store が `applicationRepository.delete(id:)` を件数分ループする。`save()` が N+1 回に割れ、途中失敗で中途半端な状態が残る（IOS-13 と同型）。
- ③④の「application + companions を softDelete して outbox に積む」処理は `SwiftDataApplicationRepository.delete:194-209` と同じ内容になる。**共通ヘルパへ切り出して両方から使う**（BE-9 の「経路が 2 本あるのに後始末が片方だけ」を作らない）。`delete-ui` T2 が同じ関数を触るため §3 の順序に注意。

### D-6 削除も編集も楽観更新しない

`await` して成功したらローカル配列を更新し、失敗したら何も変えずに `writeError` を立てる（`ApplicationStore.updateApplication:385-418` と同じ）。

- 削除は tours / events / applications の 3 配列にまたがるため、後付け undo は破綻する（IOS-13・`delete-ui` D-3）。
- 編集も、失敗時に「元の名前へ戻す」処理が並行する pull と競合しうるので同じ方針で揃える。

### D-7 共有中ツアーの削除は警告のみ

`TourGroupView` は既に `shareLinks.shareState(forTour: group.id)`（`:321`）を持つ。`.shared` のときだけ確認ダイアログに 1 行足す。

- 却下: 削除と同時に `ShareLinkStore.revoke`（`ShareLinkStore.swift:280`）を呼ぶ。revoke はネットワーク必須で、オフライン削除（FR-TE-16）と原子性が取れない。「ツアーは消えたが共有は生きている / その逆」が起きる。
- サーバー側は削除済み tour の共有を `SHARE_INVALID` に倒す（`resolve-share.use-case.ts:108-121`）ので、放置しても情報は漏れない。

### D-8 削除後に通知を再スケジュールする

`NotificationScheduler.reschedule` は Store の現在値を走査するだけなので、削除成功後に `notificationBridge.rescheduleIfAuthorized()` を呼べばよい（`delete-ui` D-6 と同じ）。App 層の変更は不要。

## 2. API 契約

**新規エンドポイントなし。既存契約の変更なし。DB 変更なし。** 実装者はこの節を正とする。

### 使う経路: `POST /v1/sync/push`（既存・変更なし）

```jsonc
// ツアー編集（FR-TE-1〜8）
{
  "mutations": [
    {
      "collection": "tours",
      "id": "<tour uuid>",
      "op": "upsert",
      "updated_at": "<ISO8601>",
      "payload": {
        "name": "STELLARIS LIVE TOUR 2026",
        "artist_name_raw": "STELLARIS",   // 空文字は null で送る
        "deleted_at": null
      }
    }
  ]
}

// ツアー削除（FR-TE-9〜17）— 依存順（tours → events → applications → application_companions）で 1 バッチ
{
  "mutations": [
    { "collection": "tours",                  "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { "name": "...", "artist_name_raw": null, "deleted_at": "<ISO8601>" } },
    { "collection": "events",                 "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { "tour_id": "<tour uuid>", ..., "deleted_at": "<ISO8601>" } },
    { "collection": "applications",           "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { "event_id": "<event uuid>", ..., "deleted_at": "<ISO8601>" } },
    { "collection": "application_companions", "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { "application_id": "<uuid>", ..., "deleted_at": "<ISO8601>" } }
  ]
}
```

- `op` は削除でも **`upsert`**。`sync.service.ts:101` は `upsert` 以外を `SYNC_APPLY_FAILED` で弾く。**`"op": "delete"` を新設しない**（BE-2）
- payload の形は既存の `syncPayload()` が正（`TourRecord+SyncPayload.swift:22-28` ほか）。**キーの追加・改名なし**（C-4）
- 並び順は `SyncEngine.drainOutbox` の依存順（identities → memberships/tours → events → applications → companions）に従う。既存の実装がそのまま使える
- サーバー側の受理挙動（変更しない・T7 で固定する）:
  - FK 検証は親の `deletedAt` を見ない（`sync.service.ts:257-261`）ので、tour tombstone の後に来る event / application tombstone も通る
  - `tours` の `(owner_id, name)` 衝突は upsert 前に事前検出され、その mutation だけ `SYNC_APPLY_FAILED` で reject される（`sync.service.ts:363-379`）。**トランザクションは abort しない**（BE-11 対策済み）
  - LWW: サーバーの `updated_at` の方が新しいと `SYNC_LWW_REJECT`

### 使わない経路（契約は現状維持）

| エンドポイント | 状態 |
|---|---|
| `PATCH /v1/tours/:id` | 既存のまま。同名衝突は `CONFLICT` 409（`tours.service.ts:56-63`） |
| `DELETE /v1/tours/:id` | 既存のまま。**配下 events / applications へ連鎖しない**（`tours.service.ts:74-91`）。iOS の実効挙動（連鎖する）とは意味が違う = R-1 |
| `GET /v1/tours/:id/matrix` | 既存のまま。削除済み tour は 404 → 共有では `SHARE_INVALID` |

## 3. タスク分解

担当は `.claude/rules/02-agents.md` に従う。**BE の製品コード変更は無い**（T7 はテストのみ）。

| # | タスク | 層 / 主な対象 | 担当 | 依存 |
|---|---|---|---|---|
| T1 | `CatalogRepository` に `deleteTour(id:)` を追加（protocol + 連鎖セマンティクスのコメント）。`InMemoryCatalogRepository` にも実装。`RemoteCatalogRepository.deleteTour` は `DELETE /v1/tours/:id`（本番未使用・D-3 の注記を残す） | `Packages/Domain/Sources/Domain/Repositories/Repositories.swift`・`Preview/InMemoryRepositories.swift`・`Packages/Networking/Sources/Networking/Remote/RemoteCatalogRepository.swift` | swift-developer | — |
| T2 | `SwiftDataCatalogRepository.updateTour` に**同名事前チェック**を追加（D-4。`deletedAt` で絞らない・自分自身は除外・衝突は `AppError.conflict`）。変更が無ければ書き込みも outbox 追加もしない（FR-TE-7）。**XCTest 先行（Red→Green）** | `Packages/DataStore/Sources/DataStore/Local/SwiftDataCatalogRepository.swift` + `DataStore/Tests` | swift-developer | — |
| T3 | `SwiftDataCatalogRepository.deleteTour(id:)` を実装（D-5 の連鎖・1 セーブ・outbox 4 種）。必要な fetch ヘルパ（`EventRecord.fetchActive(tourID:)` / `ApplicationRecord.fetchActive(eventID:)`）を追加。**申込 + companions の tombstone 化は共通ヘルパへ切り出し、`SwiftDataApplicationRepository.delete:194-209` からも使う**。**XCTest 先行（Red→Green）** | `Packages/DataStore/Sources/DataStore/Local/`・`Models/EventRecord+SyncPayload.swift`・`Models/ApplicationRecord+SyncPayload.swift` + `DataStore/Tests` | swift-developer | T1（protocol 確定後） |
| T4 | `ApplicationStore.updateTour(id:name:artistName:)` / `deleteTour(id:)` を追加（D-6 の非楽観）。削除成功時は `tours` / `events` / `applications` の 3 配列から該当分を除去。`catalogRepository == nil`（Preview）経路はローカル配列だけ更新。削除ダイアログ用の件数（公演 N / 申込 M）算出も Store に置く（View で数えない） | `Packages/Domain/Sources/Domain/Stores/ApplicationStore.swift` + `Domain/Tests` | swift-developer | T1 |
| T5 | `TourFormView`（ツアー名 + アーティスト名）を新規作成し、`AppSheet.editTour(id:)` と `SheetContentView` の分岐を追加。保存活性条件は FR-TE-3 / FR-TE-7、失敗時は画面を閉じず `writeError` を表示 | `Packages/Features/Sources/Features/Forms/TourFormView.swift`・`Navigation/AppRoute.swift`・`Forms/SheetContentView.swift` | swift-developer | T4 |
| T6 | `TourGroupView` のヘッダーに「編集」「削除」を追加（`actionButtons:378-393` の並び）。削除は `confirmationDialog`（件数入り + 共有中なら警告行 = FR-TE-10 / 14）、成功後に `notificationBridge.rescheduleIfAuthorized()`（D-8） | `Packages/Features/Sources/Features/Applications/ApplicationListView.swift` | swift-developer | T4・T5 |
| T7 | `sync.service.spec.ts` に回帰テストを追加（AC-TE-17 / AC-TE-18）。**製品コードは変更しない**。変更が必要な事実が見つかったら実装せず報告する | `apps/api/src/sync/sync.service.spec.ts` | nest-developer | — |
| T8 | docs 追従: `docs/05-ios-client.md`（ツアー編集 / 削除フローと連鎖の範囲）、`docs/09-roadmap.md`（0-11c として追記 = Q7）、`docs/plans/backend-domain-modules/api-contract.md` §5 に R-1 の注記（BE の DELETE は連鎖しないが iOS の実効挙動は連鎖する） | `docs/` | swift-developer or メイン | T6 |

### 並列実行可能なタスク

```
[T1] ‖ [T2] ‖ [T7]          ← 触るファイルが重ならない
  ↓
[T3] ‖ [T4]                  ← T3=DataStore / T4=Domain Store で別ファイル
        ↓
      [T5]
        ↓
      [T6]
        ↓
      [T8]
```

- **同一ファイルを 2 人に触らせない**: `Repositories.swift`（T1 のみ）/ `SwiftDataCatalogRepository.swift`（T2 → T3 の順で**同じ担当が直列**に）/ `ApplicationStore.swift`（T4 のみ）/ `ApplicationListView.swift`（T6 のみ）
- **`docs/plans/delete-ui/` との衝突に注意**: delete-ui の T2 と本計画の T3 がどちらも `SwiftDataApplicationRepository.delete` 周辺を触る。**delete-ui を先に完了させてから T3 を始める**か、T3 で共通ヘルパを切り出す担当を 1 人に固定する。同時進行させない
- BE（T7）と iOS の並列は可。契約は §2 で確定済み

## 4. 受入基準 → テストケース

| AC-ID | テスト | 種別 / 置き場所 |
|---|---|---|
| AC-TE-02 | 改名で `TourRecord.name` が変わり outbox に `tours` が 1 件 | XCTest `DataStore/Tests`（T2） |
| AC-TE-03 | 改名で配下 event / application の `updatedAt` と outbox が動かない | XCTest `DataStore/Tests`（T2） |
| AC-TE-04 | 既存同名（**未削除・論理削除済みの両方**）へのリネームが `.conflict` で失敗し、レコードが変わらない | XCTest `DataStore/Tests`（T2） |
| AC-TE-05 | 同値保存で `updatedAt` も outbox も動かない | XCTest `DataStore/Tests`（T2） |
| AC-TE-07 | ツアー削除で events / applications / companions に `deletedAt` が立つ | XCTest `DataStore/Tests`（T3） |
| AC-TE-08 | outbox に 4 コレクションが積まれる | XCTest `DataStore/Tests`（T3） |
| AC-TE-09 | identity / membership が消えない | XCTest `DataStore/Tests`（T3） |
| AC-TE-10 | 削除済み / 存在しない id で `.notFound` | XCTest `DataStore/Tests`（T2・T3） |
| AC-TE-06 | Store 更新後に `tours` が差し替わり `tourName(for:)` が新名を返す | XCTest `Domain/Tests`（T4） |
| AC-TE-11 | Store 削除後に 3 配列から消え `writeError == nil` | XCTest `Domain/Tests`（T4） |
| AC-TE-12 | Repository が投げると配列が変わらず `writeError` が立つ | XCTest `Domain/Tests`（T4） |
| AC-TE-17 | `tours` tombstone + 同一バッチの子 tombstone が accepted | jest `sync.service.spec.ts`（T7） |
| AC-TE-18 | 同名 `tours` upsert が個別 reject され、同一バッチの他 mutation は accepted のまま（DB に残る） | jest `sync.service.spec.ts`（T7） |
| AC-TE-01 / 13 / 14 / 15 / 16 / 19 | 手動確認（§5） | — |

**Red 先行の対象**: T2・T3・T4・T7。実装前に失敗するテストを書く。

## 5. 手動確認手順（iOS）

前提: `make up` でローカル API、シミュレータでサインイン済み、同じツアー名を持つ申込が 2 件以上（＝ツアー表に 2 行以上出る）、別ツアーの申込も 1 件以上。

1. **AC-TE-01** 申込タブ →「ツアー表」→ ツアーヘッダーの「編集」→ 現在のツアー名とアーティスト名が入ったシートが開く
2. **AC-TE-19** ツアー名を空にすると保存が押せない。戻すと押せる
3. ツアー名を変更して保存 → ツアー表の見出しが変わる →「リスト」モードでも同じ申込のツアー名が変わっている → 申込詳細でも変わっている（AC-TE-05 の対偶確認）
4. **AC-TE-04** もう一方のツアー名と同じ名前に変えて保存 →「同じ名前のツアーが既にあります」が出て保存されない
5. **AC-TE-13** ヘッダーの「削除」→ ダイアログに「公演 N 件・申込 M 件も削除されます」の実数が出る →「キャンセル」で何も起きない
6. 共有中のツアーで同じ操作 → ダイアログに共有への警告行が増える（FR-TE-14）
7. 削除を実行 → ツアー表からそのツアーが消える →「リスト」モードからも配下の申込が消える → ホームの件数が減る → 名義詳細の申込履歴からも消える（AC-TE-12 の表示側）
8. **AC-TE-09** 削除に使った申込の代表者だった名義が名義タブに残っている。その会員情報も残っている
9. **AC-TE-15** 通知許可済みの状態で、当落発表日が近い申込を含むツアーを削除 → Xcode の pending notification requests から該当が消えている
10. **AC-TE-14** 機内モードでツアー名変更 → 画面に即反映 → オンライン復帰 → 同期後に `psql` か別端末でサーバー側の `name` が変わっている。削除も同様に `deleted_at` が入る
11. **AC-TE-16** 手順 7 で削除したツアー名と同じ名前で申込を新規追加 → 新しいツアー表ができる（過去の申込は戻らない）
12. **回帰** 申込の追加・編集（ツアー付け替えを含む）・共有リンク発行が従来どおり動く

## 6. 検証ゲート

```bash
# iOS ビルド（必須）
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build

# パッケージテスト（T2〜T4 の完了ゲート）
swift test --package-path meigicho/Packages/Domain
swift test --package-path meigicho/Packages/DataStore

# BE（T7）
cd apps/api && npx tsc --noEmit && npm test -- --passWithNoTests && npm run build
```

`project.yml` を触った場合は `xcodegen generate` を忘れない（IOS-8。本計画では触らない想定）。

## 7. 実装時に踏みやすい罠（`feedback_review_patterns.md` から該当分）

| # | 本機能での具体形 |
|---|---|
| IOS-1 / IOS-3 | `CatalogRepository.updateTour` は**3 実装そろっていて呼び出し元ゼロ**だった。Store とボタンまで配線して初めて完了。Repository に `deleteTour` を足しただけで終わらせない |
| IOS-13 | 編集も削除も楽観更新しない（D-6）。`await` 後に「戻す」処理を書かない |
| IOS-5 | `Features` から `DataStore` を import しない。`TourGroupView` / `TourFormView` が触るのは `ApplicationStore` まで |
| IOS-2 | tombstone / 更新 payload のキーを独自に組み立てない。既存 `syncPayload()` を使う |
| BE-9 | 「同じデータに書き込み経路が 2 本あるのに後始末が片方だけ」。①申込 + companions の tombstone 化は `SwiftDataApplicationRepository.delete` と本機能の連鎖で**共通ヘルパに寄せる** ②同名チェックは `findOrCreateTour:219-222` とサーバー `sync.service.ts:367-379` の**3 箇所で条件を揃える**（`deletedAt` を除外しない） |
| BE-11 | ツアー削除は 1 バッチに大量の mutation が乗る。サーバー側は「事前チェックで例外を起こさない / 想定外例外は rethrow」で守られているが、T7 のテストで「1 件 reject されても他が accepted のまま DB に残る」ことを固定する |
| BE-2 | `op` に `delete` のような未定義値を送らない。削除も `upsert` + `deleted_at`（§2） |
| BE-4 | ローカルでも存在・未削除ガードを省かない（`SwiftDataCatalogRepository.updateTour:46-48` の形を踏襲） |

## 8. 委譲プロンプト案（オーケストレーター向け）

いずれも冒頭に「まず `.claude/skills/implementing-robustly/SKILL.md` を読み従う」を入れる。

- **T1 → swift-developer**: 目的（`CatalogRepository` に削除を足す）/ 対象（`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain`・`/Packages/Networking`）/ 仕様（`deleteTour(id:)` を protocol へ追加。連鎖範囲を doc コメントに明記。`RemoteCatalogRepository` は `DELETE /v1/tours/:id` を実装しつつ「本番経路では使わない」注記）/ 手本（`ApplicationRepository.delete` = `Repositories.swift:79`・`RemoteApplicationRepository.delete:47`）/ 完了条件（`swift test --package-path .../Domain` + `xcodebuild`）
- **T2 / T3 → swift-developer（同一担当・直列）**: 目的（ツアーの改名時同名チェックと削除連鎖）/ 対象（`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/DataStore`）/ 手本（`SwiftDataApplicationRepository.delete:194-209` の 1 セーブ tombstone・`findOrCreateTour:219-222` の name 検索条件）/ 仕様（本 plan の D-4・D-5 を書き写す。**`deletedAt` で絞らない同名判定**・連鎖 4 段・`context.save()` は 1 回）/ **XCTest を先に落としてから実装** / 制約（`delete-ui` と同じファイルを同時に触らない）/ 完了条件（`swift test --package-path .../DataStore`）
- **T4 → swift-developer**: 契約として D-6（非楽観）を書き写す / 既存例（`ApplicationStore.updateApplication:385-418`）/ 仕様（削除成功時に `tours` / `events` / `applications` の 3 配列を整理。件数算出も Store 側）/ 完了条件（`swift test --package-path .../Domain`）
- **T5 / T6 → swift-developer**: FR-TE-1〜6・9〜14・18〜19 と §5 の手動確認手順を書き写す / スコープ外（ツアー新規作成・マージ・公演単体編集・専用画面新設）を明記 / 完了条件（`xcodebuild` BUILD SUCCEEDED + 手動確認手順の報告）
- **T7 → nest-developer**: 対象（`/Users/yuyamorishita/オタ活アプリ/apps/api/src/sync/sync.service.spec.ts`）/ 目的（tours の tombstone 受理と同名 reject の分離を回帰で固定）/ **製品コードを変更しない・テストのみ。変更が必要な事実を見つけたら実装せず報告** / ケース（①tours tombstone が accepted ②同一バッチの events / applications / application_companions tombstone が削除済み親でも FK 検証を通る ③既存 tour と同名の tours upsert は `SYNC_APPLY_FAILED` で reject されるが、同一バッチの他 mutation は accepted のまま適用される）/ 完了条件（`cd apps/api && npm test && npx tsc --noEmit`）

レビューは実装完了後に**別セッションで** `code-reviewer` を呼び、結果を `docs/plans/tour-edit-and-delete/review.md` に保存する（`.claude/rules/04-review.md`）。
