# identity-edit-and-delete — Requirements

名義（Identity）と、それに紐づく FC 会員情報（Membership）を、登録後に**直せる・消せる**ようにする。

- 論点と確定回答: `questions-requirements.md`
  （QE1=A 追加フォームと同一 5 項目 / QE2=A 会員情報も編集・単体削除 / QE3=項目追加しない /
  QE4=名義は toolbar「編集」・会員情報はカードタップ / QE5=無変更なら送らない /
  QE6=楽観更新しない / QE7=ゲストゲート無し / QE8=未知 relation は書き戻さない / QE9=BE は変えない）
- `[Answer]:` は **planner 確定**（根拠付きで採択した既定値）であり、ユーザーが選択肢を選んだ記録ではない

## 0. 削除計画（`docs/plans/delete-ui/`）との関係

**削除は本計画で再定義しない。`docs/plans/delete-ui/` の要件・受入基準をそのまま引き継ぐ。**

| 項目 | 扱い |
|---|---|
| 名義の削除 / 申込の削除 | `delete-ui/requirements.md` FR-DEL-1〜19・AC-DEL-01〜17 をそのまま実装対象とする。**本計画で内容を書き直さない** |
| delete-ui の状態 | **計画のみ存在し未実装**（2026-08-20 時点で `docs/plans/delete-ui/` は untracked、製品コードの差分ゼロ）。Q1〜Q9 は 2026-08-20 に全件確定済み |
| 会員情報の単体削除 | delete-ui ではスコープ外だった。**本計画で新たにスコープに入れる**（QE2-A・FR-IE-16） |
| 実行順 | 両計画は `IdentityDetailView.swift` / `IdentityStore.swift` / `InMemoryRepositories.swift` を共有する。**順序とファイル占有は `plan.md` §4 が正** |

## 1. 現状のギャップ（要件ではなく事実）

| 層 | 状態 |
|---|---|
| DB | `identities` / `memberships` とも全フィールドが可変。**変更なし** |
| BE REST | `PATCH /v1/identities/:id`（全 7 項目・`update-identity.dto.ts`）/ `PATCH /v1/memberships/:id`（全 8 項目・`update-membership.dto.ts`）実装済み。**追加実装なし** |
| BE 同期 | `POST /v1/sync/push` は `identities` / `memberships` の upsert を受理（`sync-payload.mapper.ts:29-49`）。既存行の更新は名義上限チェックを通過する（`identities.service.ts:141-144`）。**追加実装なし** |
| iOS Domain | `IdentityPatch` は 7 項目、`MembershipPatch` は 8 項目とも既に定義済み（`Patches.swift:4-27`）。`IdentityRepository.update` / `MembershipRepository.update` も 3 系統実装済み |
| iOS DataStore | `SwiftDataIdentityRepository.update:40-50` / `SwiftDataMembershipRepository.update:45-62` 実装済み。削除済み行は `.notFound`、`identity_id` の付け替えは所有・生存を検証する |
| iOS Store | `IdentityStore` に**表示名・関係性・入会日を変える口が無い**（あるのは色 `:146` / 備考 `:160` / 共有スイッチ `:174` の 3 本）。**会員情報を更新する口はゼロ**（`MembershipRepository.update` は呼び出し元ゼロ = IOS-1） |
| iOS UI | 名義の編集画面が無い。会員情報カードは表示専用（`IdentityDetailView.swift:120-136`）。`AppSheet` に `editIdentity` / `editMembership` が無い（`AppRoute.swift:18-42`） |

**不足は iOS の縦串（Domain の差分計算 → Store の口 → 編集 UI と配線）だけ。DB・BE の変更はゼロ。**

現実の欠損として最も重いのは **G5**: 名義名も FC 更新日も**一度入力したら二度と直せない**。
更新日は FC 更新通知の入力そのものなので、打ち間違いが通知の誤爆として繰り返し表面化する。

## 2. 機能要件

### 名義の編集

| ID | 要件 |
|---|---|
| FR-IE-1 | 名義詳細（`IdentityDetailView`）の右上ツールバー「編集」から名義編集シートを開ける |
| FR-IE-2 | 編集シートの項目は**追加フォームと同一の 5 項目**: 氏名・呼び方（`displayName`）/ 関係性（`relation`）/ 入会日（`joinedOn`）/ 名義カラー（`colorHex`）/ メモ（`note`）。開いた時点で現在値が入っている |
| FR-IE-3 | 共有スイッチ（`historyVisible`）は編集シートに出さない。名義詳細のスイッチのまま（QE1-A） |
| FR-IE-4 | 名義詳細のカラーピッカーと備考インライン編集は**従来どおり残し、挙動も変えない**（`docs/09-roadmap.md:73` の 0-5 要件） |
| FR-IE-5 | 入会日は**未設定にできる**。現在値が未設定の名義を開いたとき、ユーザーが日付に触れなければ未設定のまま保存される（G11） |
| FR-IE-6 | 氏名が空（trim 後）のときは保存できない。保存ボタンを無効化する（`AddIdentityView.swift:68` 踏襲） |
| FR-IE-7 | ユーザーが触っていない項目は**送らない**（`Patchable.unchanged`）。関係性を操作していなければ、現在値が未知の raw 値でも `"other"` に書き潰さない（QE8-A / G10） |
| FR-IE-8 | 全項目が無変更のまま保存したときは**リポジトリを呼ばずに閉じる**。`updated_at` を進めず outbox にも積まない（QE5 / G-`IdentityRecord+Mapping.swift:42`） |
| FR-IE-9 | 表示名を変更すると、その名義を参照する全画面（名義一覧・ホーム・申込詳細の代表者/同行者・ツアー表・共有ボード）の表示が新しい名前になる。過去の申込の記録も新しい名前で表示される。**これは仕様として受け入れる**（`delete-ui` Q4 `[Answer]` の追記） |
| FR-IE-10 | 名義カラーを変更すると、名義一覧・ツアー表の色分けに反映される。アプリ全体の背景テーマには反映しない（`IdentityDetailView.swift:66` の現行文言どおり） |
| FR-IE-11 | 編集はオフラインでも成立する。ローカル（SwiftData）が SSoT で、outbox 経由で `POST /v1/sync/push` に送られる |
| FR-IE-12 | 保存に成功したらシートを閉じる。トーストは出さない（`delete-ui` Q8 と揃える） |
| FR-IE-13 | 保存に失敗したらシートを閉じず、フォーム上部にエラーを出す。UI 上の値は巻き戻さない（QE6・楽観更新しない） |
| FR-IE-14 | 未ログイン（ゲスト）は名義詳細へ到達できないため、編集にサインインゲートを掛けない（QE7） |
| FR-IE-15 | 削除済み / 存在しない名義の編集は `.notFound` として扱い、無音で成功扱いにしない |

### FC 会員情報の編集・削除

| ID | 要件 |
|---|---|
| FR-IE-16 | 名義詳細の会員情報カードをタップすると会員情報編集シートが開く。項目は**追加フォームと同一の 4 項目**: FC / アーティスト名（`fanClubNameRaw`）/ 会員番号の下 4 桁（`memberNoLast4`）/ 更新日（`renewalOn`・未設定可）/ 年会費（`feeYen`）（QE3） |
| FR-IE-17 | 編集シートの最下部に「この会員情報を削除」（destructive）を置く。確認ダイアログを経由する（QE4） |
| FR-IE-18 | 会員情報を削除すると、その会員情報を `rep_membership_id` で参照している未削除の申込の当該フィールドを `null` にクリアする（BE `memberships.service.ts:156-165` と同じ不変条件。**`delete-ui` T1 が作る共通処理を呼ぶ**） |
| FR-IE-19 | フォームに出していない `rank` / `auto_renew` / `note` は編集で**値が消えない**（`.unchanged` で送らない・QE3 の帰結） |
| FR-IE-20 | 会員情報の追加時にだけ出る通知許可シート（`AddMembershipView.swift:79-85,100-104`）は、**編集では出さない** |
| FR-IE-21 | 更新日の変更・会員情報の削除の後、ローカル通知を再スケジュールする（`NotificationBridge.rescheduleIfAuthorized`）。古い更新日の通知が残らない |
| FR-IE-22 | FC 名が空（trim 後）のときは保存できない（`AddMembershipView.swift:73` 踏襲） |
| FR-IE-23 | 会員番号は編集でも**下 4 桁だけ**を扱う。全桁を端末に持たない（`Models.swift:44` / `contract-mapping.md` C5） |

### 名義・申込の削除（`delete-ui` から引き継ぎ）

| ID | 要件 |
|---|---|
| FR-IE-24 | `delete-ui/requirements.md` の FR-DEL-1〜FR-DEL-19 をそのまま本計画の要件とする。**内容をここに複製しない** |

## 3. 非機能要件・制約

| ID | 内容 |
|---|---|
| NFR-1 | 既存の**追加**フロー（名義追加 → 会員情報追加への連続導線 = `AddIdentityView.swift:53,88`、通知許可シート）の振る舞いを変えない |
| NFR-2 | 名義詳細の既存インライン編集 3 経路（カラー・備考・共有スイッチ）の振る舞いを変えない（楽観更新のまま） |
| NFR-3 | `Features` は `DataStore` / `Networking` を直接参照しない（IOS-5）。UI が触るのは `IdentityStore` まで |
| NFR-4 | `DesignSystem` の `MembershipCard`（`FormComponents.swift:221-229`）の API を変えない。タップ可能化は Features 側で包む |
| NFR-5 | 差分計算（どのフィールドを `.set` にするか / 全件 `.unchanged` か）は `Domain` の純粋関数に置き、XCTest で Red→Green（`ApplicationEditPlanner` の前例 = `application-edit/plan.md` D-2） |
| NFR-6 | 3 層契約（Prisma ↔ NestJS ↔ iOS）を片側だけ変えない。本機能は**契約変更なし**（`plan.md` §3） |
| C-1 | iOS の書き込み経路は REST PATCH ではなくローカル + `POST /v1/sync/push`（`application-edit/plan.md` D-1 / `delete-ui` C-2） |
| C-2 | date-only（`joined_on` / `renewal_on`）の変換は既存の `APIDateFormat`（JST 基準・`Core/APIDateFormat.swift:15-38`）を使い、独自変換を新設しない |
| C-3 | 同期 payload のキーは既存の `syncPayload()` が正（`IdentityRecord+SyncPayload.swift:7-26` / `MembershipRecord+SyncPayload.swift:30-41`）。キーの追加・改名をしない |
| C-4 | 会員情報の単体削除（FR-IE-16〜18）は `delete-ui` T1（`repMembershipID` クリアの共通処理）に依存する。**T1 完了前に着手しない** |
| C-5 | BE の製品コードを変更しない。BE 側の作業は jest の回帰テスト追加のみ |

## 4. スコープ外

- **BE の `POST /v1/sync/push` へのフィールド単位検証の追加**（QE9 / §7 R-1）。既存の全 6 コレクションに共通する穴で、本計画の付随作業の範囲を超える。技術負債として記録し別計画へ
- **会員情報フォームへの `rank` / `auto_renew` / `note` の追加**（QE3）。追加フォーム側も同時に変える必要があり、製品判断が別
- **共有スイッチの編集フォームへの移動**、名義詳細のインライン編集の撤去（QE1-B）
- **一覧からのスワイプ編集 / スワイプ削除**（`delete-ui` Q1-B と同じ理由）
- **削除の取り消し / 復元 UI**（`delete-ui` Q7）
- **ツアー / 公演の編集・削除 UI**（別セッションで並行計画中）
- **グループ機能・会員番号のフル桁化**（別セッションで並行計画中）
- **申込の編集**（`docs/plans/application-edit/` で実装済み・2026-08-19 完了）
- **名義の並び替え（`sortOrder`）の UI**。`IdentityPatch.sortOrder` は存在するが、一覧の並びは `IdentitySortOrder` の 3 種ソートで決まっており手動並び替えの UI が無い（現状維持）

## 5. 受入基準

### 名義の編集

| AC-ID | 基準 | 検証方法 |
|---|---|---|
| AC-IE-01 | 名義詳細の右上「編集」からシートが開き、5 項目すべてに現在値が入っている | 手動 |
| AC-IE-02 | 表示名だけ変更 → `IdentityPatch.displayName` のみ `.set`、他 4 項目は `.unchanged` | XCTest（Domain・純粋関数） |
| AC-IE-03 | 何も変えずに保存 → 差分が「変更なし」と判定され、リポジトリが呼ばれない（Fake Repository の呼び出し回数 0） | XCTest（Domain・Store） |
| AC-IE-04 | 入会日が未設定の名義を開き、日付に触れずに保存 → `joinedOn` は `.unchanged`（`.set(today)` にならない） | XCTest（Domain） |
| AC-IE-05 | 入会日を「未設定にする」操作 → `joinedOn` が `.set(nil)`（キー省略ではなく明示的な null） | XCTest（Domain） |
| AC-IE-06 | `relation` の Picker を操作していなければ `.unchanged`。現在値が未知 raw の行を保存しても `"other"` に書き潰されない | XCTest（Domain） |
| AC-IE-07 | 表示名を空白のみにすると保存ボタンが無効 | 手動 |
| AC-IE-08 | 保存に成功すると `IdentityStore.identities` の当該要素が更新され、`actionError == nil` | XCTest（Domain・Fake Repository） |
| AC-IE-09 | リポジトリが投げると `identities` が変わらず `actionError` が立ち、シートを閉じない | XCTest（Domain）+ 手動 |
| AC-IE-10 | 名義編集で SwiftData の行が更新され、outbox に `identities` が 1 件積まれる。`updatedAt` が進む | XCTest（DataStore） |

### FC 会員情報の編集・削除

| AC-ID | 基準 | 検証方法 |
|---|---|---|
| AC-IE-11 | `rank` / `autoRenew` / `note` に値が入った会員情報を編集フォームで開いて FC 名だけ変えて保存 → **3 項目の値が保持される** | XCTest（DataStore） |
| AC-IE-12 | 更新日を「未設定」に切り替えて保存 → `renewalOn` が `.set(nil)` になり、ローカル行が null になる | XCTest（Domain + DataStore） |
| AC-IE-13 | 会員情報編集で outbox に `memberships` が 1 件積まれる | XCTest（DataStore） |
| AC-IE-14 | 会員情報を削除すると `deletedAt` が立ち、その id を `repMembershipID` に持つ未削除の申込が `nil` にクリアされ、`applications` も outbox に積まれる | XCTest（DataStore） |
| AC-IE-15 | 会員情報を削除しても、その名義と申込は残る（`deletedAt == nil`） | XCTest（DataStore） |
| AC-IE-16 | 会員情報の編集では通知許可シートが出ない（追加では従来どおり出る） | 手動 |
| AC-IE-17 | 更新日を変更 → 通知が再スケジュールされ、古い日付の通知が残らない | 手動 |
| AC-IE-18 | 削除済み会員情報の編集は `.notFound` を投げ、新規行を作らない | XCTest（DataStore） |

### 横断・回帰

| AC-ID | 基準 | 検証方法 |
|---|---|---|
| AC-IE-19 | 機内モードで名義名を変更 → 一覧に反映される。オンライン復帰後、サーバー側にも反映される | 手動 |
| AC-IE-20 | Free 上限（3 件）まで名義がある状態で既存名義を編集して保存できる（`PLAN_LIMIT_IDENTITY` にならない） | jest（`sync.service.spec.ts`）+ 手動 |
| AC-IE-21 | 名義名を変更すると、その名義を代表とする過去の申込詳細・ツアー表・共有プレビューの表示名も変わる | 手動 |
| AC-IE-22 | （回帰）名義の追加フローが従来どおり動く（保存後に会員情報追加へ進む）。会員情報の追加、通知許可シート、詳細のカラーピッカー・備考インライン編集・共有スイッチも従来どおり | 手動 |
| AC-IE-23 | `delete-ui/requirements.md` の AC-DEL-01〜17 をすべて満たす | 同計画の §5 に従う |

## 6. 影響範囲

| 層 | 対象 |
|---|---|
| DB | **変更なし** |
| BE | **製品コード変更なし**。`apps/api/src/sync/sync.service.spec.ts` にテスト追加のみ（AC-IE-20 と `delete-ui` AC-DEL-17） |
| iOS Domain | `Models/`（`IdentityEditFormInput` / `IdentityEditPlanner` / `MembershipEditFormInput` / `MembershipEditPlanner` を新規）、`Stores/IdentityStore.swift`（`updateIdentity` / `updateMembership` / `deleteMembership` を追加）、`Tests/` |
| iOS DataStore | **製品コード変更は原則なし**（`update` は実装済み）。会員情報削除の `repMembershipID` クリアは `delete-ui` T1 が作る共通処理を `SwiftDataMembershipRepository.delete` から呼ぶ。テスト追加 |
| iOS Features | `Forms/IdentityFormView.swift`（`AddIdentityView` から抽出 + edit）、`Forms/MembershipFormView.swift`（`AddMembershipView` から抽出 + edit）、`Forms/SheetContentView.swift`、`Navigation/AppRoute.swift`（`AppSheet` に 2 ケース）、`Detail/IdentityDetailView.swift`（編集ツールバー + カードのタップ化） |
| iOS App | 変更なし（通知再スケジュールは既存の `NotificationBridge.rescheduleIfAuthorized` を Features から呼ぶ） |
| docs | `docs/05-ios-client.md`（S3 名義詳細に編集導線、フォーム画面の追加）、`docs/09-roadmap.md`（**0-5b 名義編集 / 0-6b 会員情報編集** を 0-11b と同じ形で追記）、`docs/01-product-overview.md`（R1 系に「名義・会員情報は後から編集できる」を明記） |

## 7. リスク・既知の不整合

| # | 内容 | 扱い |
|---|---|---|
| R-1 | **`POST /v1/sync/push` の payload にフィールド単位の検証が無い**（`sync/dto/sync.dto.ts:29-31` の `@IsObject()` のみ）。`PATCH` DTO の `@MinLength(1)` / `@IsIn(IDENTITY_RELATIONS)` / `@MaxLength(60)` は同期経路では効かず、Prisma 側も `displayName String` / `relation String` で無制約（`schema.prisma:106-107`）。BE-9 型「書き込み経路が 2 本あるのに検証が片方だけ」 | **本計画が作った穴ではなく既存**。iOS 側でガード（FR-IE-6 / FR-IE-22 / 差分計算）し、BE 側は別計画へ切り出す（QE9） |
| R-2 | `IdentityRecord.relation` の getter が未知値を黙って `.other` に落とす（`IdentityRecord.swift:57-59`）。編集で書き戻すと元の raw 値が失われる | FR-IE-7 / AC-IE-06 で「触っていなければ送らない」ようにして実害を止める。getter 自体は変えない（他の読み経路に波及するため） |
| R-3 | 同期 push は**スカラー全件**を送るため（`syncPayload()`）、`Patchable` によるフィールド単位の保護は**ローカル書き込みまで**しか効かない。別端末が同じ名義を同時編集すると、レコード単位の LWW で片方の変更が丸ごと消える | 既存仕様（`docs/05-ios-client.md:930`）。本計画では変更しない。`docs/09-roadmap.md:119`（1-18 同期の耐障害テスト）の対象 |
| R-4 | 名義詳細に「編集」ツールバーと 3 つのインライン編集が併存する（QE1-A）。同じフィールドへの書き込み経路が 2 本になる | `Patchable` により未操作フィールドは送らないので書き潰しは起きない。ただしレビュー時に「編集フォームが `.set` を過剰に立てていないか」を必ず見る（AC-IE-02） |
| R-5 | 表示名の変更が過去の申込・共有ボード・ツアー表の表示に遡って反映される（FR-IE-9）。`ApplicationCompanion.display_name` は追随しないため、代表者としては新名・同行者としては旧名という混在が起きうる（`tour-matrix.service.ts:107-110` は `companion.identity.displayName` を優先するのでツアー表では新名） | 既存の同行者モデルの設計に由来する。本計画では変更せず、手動確認（AC-IE-21）で挙動を記録する |
| R-6 | `delete-ui` が未実装のまま本計画を並行実装すると、`IdentityDetailView.swift` / `IdentityStore.swift` / `InMemoryRepositories.swift` で衝突する | `plan.md` §4 の実行順で直列化する（delete-ui を先に完了させる） |
| R-7 | `docs/09-roadmap.md` に「名義編集」の項目が無い（0-5 名義詳細には備考インライン編集とカラーピッカーしか書かれていない = `:73`）。ロードマップ外の追加になる | 申込編集が 0-11b として追記された前例（`:80`）に倣い、**0-5b として docs に追記する**（§6 docs 行）。追記なしで実装しない |
