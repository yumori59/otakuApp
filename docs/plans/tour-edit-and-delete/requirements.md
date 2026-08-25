# tour-edit-and-delete — Requirements

登録済みの**ツアー（Tour）** をアプリ内から**編集（名前 / アーティスト名）** し、**削除**できるようにする。

- 論点と暫定回答: `questions-requirements.md`（Q1=A ツアー表ヘッダー / Q2=A 名前+アーティストのみ / Q3=A 配下も連鎖削除 / Q4=A 警告のみ / Q5=A ローカル事前チェックで拒否 / Q6 復元は対象外 / Q7 ロードマップ 0-11c として追記）
- **未回答のまま計画している**。回答が違ったら本ファイルと `plan.md` を先に直す

## 1. 現状のギャップ（要件ではなく事実）

| 層 | 状態 |
|---|---|
| BE REST | `PATCH /v1/tours/:id`（`tours.controller.ts:42-49` / `tours.service.ts:47-72`・同名衝突は `CONFLICT` 409）と `DELETE /v1/tours/:id`（`:51-55` / `:78-91`・ソフトデリート・冪等・**連鎖しない**）ともに実装済み |
| BE 同期 | `tours` は同期対象（`sync-collections.ts:5`）。push payload は `name` / `artist_name_raw` / `deleted_at`（`sync-payload.mapper.ts` の `case 'tours'`）。`(owner_id, name)` 衝突は upsert 前に事前検出して `SYNC_APPLY_FAILED` で個別 reject（`sync.service.ts:363-379`）。**論理削除済みの同名とも衝突する**（プレーン unique index） |
| iOS Repository | `CatalogRepository.updateTour(id:_:)` は protocol・SwiftData（outbox 込み）・Remote・InMemory の**全実装が揃っている**（`Repositories.swift:66` / `SwiftDataCatalogRepository.swift:44-54` / `RemoteCatalogRepository.swift:35-42` / `InMemoryRepositories.swift:93`）。**呼び出し元がゼロ**（実装済み未配線 = IOS-1） |
| iOS Repository（削除） | `CatalogRepository` に **`deleteTour` が無い**。protocol からして存在しない |
| iOS Store | `ApplicationStore` は `tours` を保持し join に使うだけ（`ApplicationStore.swift:13,156-158`）。**ツアーの更新 / 削除メソッドが無い** |
| iOS UI | ツアー専用画面はゼロ。ツアーが見えるのは申込タブの「ツアー表」モード（`TourGroupView` = `ApplicationListView.swift:304-453`）と申込フォームのツアー名欄だけ。編集 / 削除の導線は無い |

**不足は「`CatalogRepository.deleteTour` の新設」「`ApplicationStore` の 2 メソッド」「ツアー表ヘッダーの導線 + 編集シート」**。編集の Repository 層は既にある。

### 既存の「ツアー名の変更」との違い（重要）

申込編集（`docs/plans/application-edit/`）でツアー名を変えると、`ApplicationEditPlanner.makeTourDraft`（`ApplicationEditPlanner.swift:179-188`）が
**新しい UUID の TourDraft を作り、その申込 1 件だけを新ツアーへ付け替える**（find-or-create）。元のツアーと他の申込はそのまま残る。
本機能で必要なのは、**ツアーそのものの改名＝配下の申込全部に効く変更**。両者は別物であり、片方で代替できない。

## 2. 機能要件

### ツアーの編集

| ID | 要件 |
|---|---|
| FR-TE-1 | ツアー表モードの各ツアーヘッダーから、そのツアーを編集できる（Q1-A） |
| FR-TE-2 | 編集できるのは**ツアー名**と**アーティスト名**の 2 項目（BE `UpdateTourDto` と一致 = Q2-A） |
| FR-TE-3 | ツアー名は必須。空白のみは不可。前後の空白は trim する（BE は `@MinLength(1)` / `@MaxLength(200)`） |
| FR-TE-4 | アーティスト名は空でよい。空文字は `null` として送る（`TourRecord.syncPayload()` の `optionalString`） |
| FR-TE-5 | 保存すると、そのツアーを参照する**全ての申込の表示**（ツアー表の見出し・申込一覧のツアー名・申込詳細）に即座に反映される |
| FR-TE-6 | 既に同じ名前のツアーがある場合は保存させず、「同じ名前のツアーが既にあります」と表示する。**判定には論理削除済みのツアーも含める**（サーバーの unique 制約に合わせる = Q5-A） |
| FR-TE-7 | 変更が無い状態（名前もアーティスト名も同じ）で保存を押しても書き込みを発生させない |
| FR-TE-8 | 編集はオフラインでも成立する。ローカル（SwiftData）が SSoT で、outbox 経由で `POST /v1/sync/push` に送られる |

### ツアーの削除

| ID | 要件 |
|---|---|
| FR-TE-9 | ツアー表モードの各ツアーヘッダーから、そのツアーを削除できる |
| FR-TE-10 | 削除は確認ダイアログを経由する。文言に**配下の公演件数**と**申込件数**を実データから埋め込む |
| FR-TE-11 | ツアーを削除すると、そのツアーの**公演（Event）・申込（Application）・同行者（ApplicationCompanion）も同時にソフトデリート**される（Q3-A） |
| FR-TE-12 | 削除したツアーはツアー表から消える。配下の申込は申込リスト・ホームの件数・名義詳細の申込履歴からも消える |
| FR-TE-13 | 削除しても、その申込の**代表者 / 同行者だった名義（Identity）と会員情報（Membership）は削除しない** |
| FR-TE-14 | 削除対象のツアーが**共有中**の場合、確認ダイアログに「共有中の相手はこのツアー表を開けなくなります」を追加する。共有リンクは自動失効させない（Q4-A） |
| FR-TE-15 | 削除後、ローカル通知を再スケジュールする。削除した申込の当落発表通知が残らない（`NotificationScheduler.reschedule`） |
| FR-TE-16 | 削除はオフラインでも成立する（FR-TE-8 と同じ経路） |
| FR-TE-17 | 削除済み / 存在しないツアーへの削除は `.notFound` として扱い、無音で成功扱いにしない |

### 共通

| ID | 要件 |
|---|---|
| FR-TE-18 | 編集 / 削除に失敗したら UI 上のデータを変えず、既存のエラー表示（`writeError` → `ErrorBar`）に理由を出す |
| FR-TE-19 | 未ログイン（ゲスト）にはツアー表自体が出ない（`ApplicationsTab.content:88-97`）ので、専用のログイン誘導は不要 |
| FR-TE-20 | 削除したツアーと同じ名前で新しく申込を追加すると、既存の find-or-create が論理削除済みツアーを**復活**させる（`SwiftDataApplicationRepository.findOrCreateTour` / `tours.service.ts:114-144`）。このとき連鎖削除済みの公演・申込は**復活しない**。既存挙動として受け入れる |

## 3. 非機能要件・制約

| ID | 内容 |
|---|---|
| NFR-1 | 既存の申込追加・申込編集・共有フローの振る舞いを変えない |
| NFR-2 | `Features` は `DataStore` / `Networking` を直接参照しない（IOS-5）。UI が触るのは `ApplicationStore` まで |
| NFR-3 | 振る舞いロジック（連鎖対象の決定・同名判定・件数算出）は `Domain` / `DataStore` のテスト可能な位置に置き、XCTest で Red→Green |
| NFR-4 | 3 層契約（Prisma ↔ NestJS ↔ iOS）を片側だけ変えない。本機能は**契約変更なし**（`plan.md` §2） |
| C-1 | 削除は**ソフトデリートのみ**。物理削除は行わない（`docs/09-roadmap.md:535`） |
| C-2 | iOS の書き込み経路は REST `PATCH` / `DELETE` ではなくローカル + `POST /v1/sync/push`（`docs/plans/application-edit/plan.md` D-1・`docs/plans/delete-ui/plan.md` D-1 と同じ） |
| C-3 | `POST /v1/tours` は無い。**ツアーの新規作成 UI は作らない**（作成経路は申込の find-or-create のみ = D9） |
| C-4 | tombstone / 更新の payload は既存の `syncPayload()` をそのまま使う。キーの追加・改名をしない |
| C-5 | 連鎖削除の 1 サイクル分（tour + events + applications + companions）は**同一 `ModelContext` の 1 回の `save()`** で完結させる |

## 4. スコープ外

- ツアーの新規作成 UI（C-3）
- 同名ツアーへの**統合 / マージ**（Q5-B）。既存ツアー名へのリネームは拒否するだけ
- ツアー表からの公演（Event）単体の編集・削除。公演の編集は申込編集（`docs/plans/application-edit/`）が担当
- 削除の取り消し / 復元 UI（Q6・`docs/plans/delete-ui/` と同じ扱い）
- 専用のツアー一覧画面・`AppRoute.tour` の新設（Q1-B）
- 共有ボード（受け取り側）からのツアー編集・削除
- BE の製品コード変更（回帰テスト追加のみ）
- 削除と同時の共有リンク失効（Q4-B）

## 5. 受入基準

| AC-ID | 基準 | 検証方法 |
|---|---|---|
| AC-TE-01 | ツアー表の各ツアーヘッダーに編集・削除の導線があり、編集を押すとツアー名 / アーティスト名の入った編集シートが開く | 手動 |
| AC-TE-02 | ツアー名を変更して保存すると、`TourRecord.name` が変わり outbox に `tours` が 1 件積まれる | XCTest（DataStore） |
| AC-TE-03 | ツアー名を変更しても、配下の公演・申込のレコードは書き換わらない（`updatedAt` も動かない） | XCTest（DataStore） |
| AC-TE-04 | 既存ツアーと同名にリネームしようとすると保存されず `.conflict` 相当のエラーになる。**論理削除済みの同名でも同じ**（FR-TE-6） | XCTest（DataStore） |
| AC-TE-05 | 名前もアーティスト名も変わっていない保存はローカル書き込みも outbox 追加も発生させない（FR-TE-7） | XCTest（Domain または DataStore） |
| AC-TE-06 | `ApplicationStore` の更新後、`tours` の該当要素が差し替わり、`tourName(for:)` が新しい名前を返す | XCTest（Domain） |
| AC-TE-07 | ツアーを削除すると、そのツアーの events / applications / companions すべてに `deletedAt` が立つ | XCTest（DataStore） |
| AC-TE-08 | ツアー削除で outbox に `tours` / `events` / `applications` / `applicationCompanions` の 4 種が積まれる | XCTest（DataStore） |
| AC-TE-09 | ツアー削除で、代表者 / 同行者だった `IdentityRecord` / `MembershipRecord` は消えない | XCTest（DataStore） |
| AC-TE-10 | 削除済み / 存在しないツアー id の削除は `.notFound` を投げる（FR-TE-17） | XCTest（DataStore） |
| AC-TE-11 | `ApplicationStore` の削除後、`tours` からツアーが消え、`applications` からそのツアーの申込が消え、`events` からも消える。`writeError` は nil | XCTest（Domain） |
| AC-TE-12 | Repository が投げたときは `tours` / `applications` が一切変わらず `writeError` が立つ（楽観更新しない） | XCTest（Domain） |
| AC-TE-13 | 削除の確認ダイアログに公演 N 件・申込 M 件の実数が入る。共有中なら共有への警告文が増える | 手動 |
| AC-TE-14 | 機内モードで編集 / 削除 → 画面に即反映。オンライン復帰後、サーバー側にも反映される（`deleted_at` / 新しい `name`） | 手動 |
| AC-TE-15 | 削除後に通知が再スケジュールされ、削除した申込の当落通知が残らない | 手動 |
| AC-TE-16 | 削除したツアーと同じ名前で申込を新規追加すると、ツアーが復活し新しいツアー表ができる（過去の申込は戻らない = FR-TE-20） | 手動 |
| AC-TE-17 | （BE 回帰）`tours` の tombstone push が accepted され、同一バッチの events / applications / companions tombstone も FK 検証を通る | jest（`sync.service.spec.ts`） |
| AC-TE-18 | （BE 回帰）既存 tour と同名への `tours` upsert は `SYNC_APPLY_FAILED` で個別 reject され、**同一バッチの他の mutation は accepted のまま**（トランザクションが巻き添えで死なない = BE-11） | jest（`sync.service.spec.ts`） |
| AC-TE-19 | 編集シートでツアー名を空にすると保存ボタンが押せない（FR-TE-3） | 手動 |

## 6. 影響範囲

| 層 | 対象 |
|---|---|
| DB | **変更なし** |
| BE | **製品コード変更なし**。`apps/api/src/sync/sync.service.spec.ts` に回帰テスト追加のみ |
| iOS Domain | `Repositories.swift`（`CatalogRepository.deleteTour` 追加 + 連鎖セマンティクスのコメント）、`Stores/ApplicationStore.swift`（`updateTour` / `deleteTour` と、削除時のローカル配列整理）、`Preview/InMemoryRepositories.swift` |
| iOS DataStore | `Local/SwiftDataCatalogRepository.swift`（`deleteTour` の連鎖 + 同名事前チェック）、`Models/EventRecord+SyncPayload.swift`（`fetchActive(tourID:)` 相当の追加）、`Models/ApplicationRecord+SyncPayload.swift`（`fetchActive(eventID:)` 相当の追加） |
| iOS Networking | `Remote/RemoteCatalogRepository.swift`（`deleteTour` = `DELETE /v1/tours/:id`。本番経路では使わないが protocol 準拠のため実装） |
| iOS Features | `Applications/ApplicationListView.swift`（`TourGroupView` ヘッダーの導線）、`Navigation/AppRoute.swift`（`AppSheet.editTour(id:)`）、`Forms/SheetContentView.swift`、新規 `Forms/TourFormView.swift` |
| docs | `docs/05-ios-client.md`（ツアー編集 / 削除フロー）、`docs/09-roadmap.md`（0-11c として追記 = Q7） |

## 7. リスク・既知の不整合

| # | 内容 | 扱い |
|---|---|---|
| R-1 | BE の `DELETE /v1/tours/:id` は連鎖しないのに、iOS の削除（sync push 経由）は連鎖する。**同じ「ツアー削除」で 2 つの意味が併存する**（BE-9 の型） | iOS は REST DELETE を使わない（C-2）ので実害は無いが、`api-contract.md` §5 の「連鎖させない」に**iOS の実効挙動は連鎖する**旨を注記する。`delete-ui` の名義削除でも同じ形（BE は memberships に連鎖しないが iOS は連鎖する） |
| R-2 | ツアー名の unique 制約は**論理削除済みも占有する**（`tours_owner_name_uniq` は部分 index ではない）。削除したツアー名へのリネームができない | FR-TE-6 で「同じ名前のツアーが既にあります」と出す。ユーザーには削除済みが見えないので理由がわからない。文言でカバーしきれないため R-2 として残す |
| R-3 | ローカルの `findOrCreateTour` と `TourRecord` の unique 判定は `ownerID` で絞っていない（`SwiftDataApplicationRepository.swift:219-222` は name のみ）。ローカル DB は 1 ユーザー分しか持たない前提 | 既存前提。FR-TE-6 のローカル事前チェックも同じ前提（name のみ）で書き、前提をコメントに残す |
| R-4 | 同期の LWW は「削除より新しい編集が勝つ」（`docs/05-ios-client.md:930`）。別端末で同じツアーの申込を編集中に削除すると、その申込だけ復活しうる | 既存仕様。本計画では変更しない |
| R-5 | 共有中ツアーを削除すると共有相手は `SHARE_INVALID`（`resolve-share.use-case.ts:108-121`）。共有リンク一覧にはツアー名が出続ける（`shares.service.ts:190-194` は `deletedAt` で絞っていない） | FR-TE-14 の警告で受け入れる |
| R-6 | 大量の申込を持つツアー（数百件）の削除は 1 トランザクションで全件 tombstone を作り、push 1 バッチが大きくなる | Phase 0 の想定規模（`ApplicationStore.maxPages` = 4,000 件上限）では許容。実測で問題が出たら分割を検討 |
| R-7 | `docs/09-roadmap.md` に本機能の番号付き項目が無い（Q7） | 0-11c として追記する。planner としてスコープ逸脱ではなく Phase 0 の穴埋めと判断 |
