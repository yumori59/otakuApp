# delete-ui — Requirements

登録済みの**名義（Identity）** と**申込（Application）** をアプリ内から削除できるようにする。

- 前提となる論点と確定回答: `questions-requirements.md`
  （Q1=A 詳細画面のみ / Q2=確認ダイアログ必須 / Q3=A 会員情報は連鎖削除 / Q4=A 申込は残す / Q5=A「削除された名義」表示 + リンク無効 / Q6=表示名は残す / Q7=復元 UI は対象外 / Q8=1 つ戻る / Q9=ゲストゲート無し）
- **2026-08-20 に Q1〜Q9 を再点検し、上記デフォルト仮定を全件確定回答として採択した**（`questions-requirements.md`
  「確定ステータス」節）。`[Answer]:` は planner 確定であり、ユーザーが選択肢を選んだ記録ではない。
  差分は Q1 の追記 1 件のみで、本ファイルと `plan.md` の記述変更は不要だった。
- **本計画は未実装**（2026-08-20 時点。`git status` 上も `docs/plans/delete-ui/` が untracked で、
  製品コードの差分はゼロ）。実装は `docs/plans/identity-edit-and-delete/plan.md` §4 の実行順に従う。

## 0. 関連計画

名義編集・会員情報編集は本計画のスコープ外で、`docs/plans/identity-edit-and-delete/` が扱う。
両計画は `IdentityDetailView.swift` / `IdentityStore.swift` / `InMemoryRepositories.swift` を共有するため、
**実行順とファイル占有は `identity-edit-and-delete/plan.md` §4 を正とする**（本計画を先に流す）。

## 1. 現状のギャップ（要件ではなく事実）

| 層 | 状態 |
|---|---|
| BE REST | `DELETE /v1/identities/:id`（`identities.service.ts:116-129`）・`DELETE /v1/applications/:id`（`applications.service.ts:108-125`）ともに実装済み・ソフトデリート・冪等 |
| BE 同期 | `POST /v1/sync/push` は 6 コレクションすべてで `deleted_at` を受理する（`sync-payload.mapper.ts:38,50,56,65,80,88`）。tombstone push の**回帰テストは無い**（`sync.service.spec.ts` に `deleted_at` の記述ゼロ） |
| iOS Repository | `IdentityRepository.delete` / `ApplicationRepository.delete` は protocol・SwiftData・InMemory すべて実装済み。**呼び出し元がゼロ**（IOS-1 の「実装済み未配線」） |
| iOS Store | `IdentityStore` / `ApplicationStore` に削除メソッドが**無い**。ここで縦串が切れている |
| iOS UI | 名義詳細・申込詳細ともに削除ボタンが**無い** |

つまり不足は **Store の 2 メソッドと詳細画面 2 つの導線**、および削除後に生じる副作用（会員情報・通知・削除済み名義参照の表示）の始末。

## 2. 機能要件

### 申込の削除

| ID | 要件 |
|---|---|
| FR-DEL-1 | 申込詳細（`ApplicationDetailView`）から申込を削除できる。導線は本文最下部の destructive ボタン「この申込を削除」 |
| FR-DEL-2 | 削除は確認ダイアログを経由する。文言に「同行者の記録も一緒に削除されます」を含める |
| FR-DEL-3 | 申込を削除すると、その申込の同行者（`ApplicationCompanion`）も同時にソフトデリートされる（BE `applications.service.ts:118-124` と同じ） |
| FR-DEL-4 | 削除に成功したら詳細画面を閉じて呼び出し元へ戻る。申込一覧・ツアー表・ホーム・名義詳細の申込履歴から即座に消える |
| FR-DEL-5 | 削除しても、その申込が参照していた公演（Event）・ツアー（Tour）は削除しない（他の申込が参照しうる） |

### 名義の削除

| ID | 要件 |
|---|---|
| FR-DEL-6 | 名義詳細（`IdentityDetailView`）から名義を削除できる。導線は本文最下部の destructive ボタン「この名義を削除」 |
| FR-DEL-7 | 削除は確認ダイアログを経由する。文言に**その名義の会員情報の件数**と**その名義を代表とする申込の件数**を実データから埋め込む |
| FR-DEL-8 | 名義を削除すると、その名義に紐づく FC 会員情報（Membership）も同時にソフトデリートされる（Q3-A） |
| FR-DEL-9 | 名義を削除しても、その名義を代表者 / 同行者とする申込は**削除しない**（Q4-A・`docs/05-ios-client.md:920`） |
| FR-DEL-10 | 会員情報の連鎖削除に伴い、削除される membership を `rep_membership_id` で参照している未削除の申込は同時に `null` へクリアする（BE `memberships.service.ts:156-165` と同じ不変条件 FR-AP-4 を守る） |
| FR-DEL-11 | 削除に成功したら名義詳細を閉じて名義一覧へ戻る。名義一覧・ホーム・共有プレビューから即座に消える |
| FR-DEL-12 | 名義を削除すると Free プランの名義枠が 1 つ空く（BE は `deletedAt: null` のみを数える = `identities.service.ts:65-67`） |

### 削除後の表示・副作用

| ID | 要件 |
|---|---|
| FR-DEL-13 | 削除済み名義を代表者とする申込の詳細では、代表者欄を「削除された名義」と表示し、名義詳細へのリンクを無効化する（現状は「不明 ›」で行き止まり画面に飛ぶ = `ApplicationDetailView.swift:134`） |
| FR-DEL-14 | 同行者に削除済み名義が含まれる場合、表示名（`display_name`）はそのまま出し、名義詳細へのリンクだけ無効化する |
| FR-DEL-15 | 削除後、ローカル通知を再スケジュールする。削除した申込の当落発表通知・削除した名義の FC 更新通知が残らない（`NotificationScheduler.reschedule:34-70`） |
| FR-DEL-16 | ホームの「更新が近い会員情報」件数（`IdentityStore.expiringMembershipCount:91-97`）に削除済み名義の会員情報が含まれない |
| FR-DEL-17 | 削除はオフラインでも成立する。ローカル（SwiftData）が SSoT で、tombstone は outbox 経由で `POST /v1/sync/push` に送られる |
| FR-DEL-18 | 削除に失敗したら画面を閉じず、既存の `ErrorBar` に理由を出す。UI 上のデータは何も消さない |
| FR-DEL-19 | 既に削除済み / 存在しない対象への削除は `.notFound` として扱い、無音で成功扱いにしない |

## 3. 非機能要件・制約

| ID | 内容 |
|---|---|
| NFR-1 | 既存の追加・編集フローの振る舞いを変えない |
| NFR-2 | `Features` は `DataStore` / `Networking` を直接参照しない（IOS-5）。UI が触るのは `IdentityStore` / `ApplicationStore` まで |
| NFR-3 | 振る舞いロジック（連鎖対象の決定・件数算出）は `Domain` / `DataStore` のテスト可能な位置に置き、XCTest で Red→Green |
| NFR-4 | 3 層契約（Prisma ↔ NestJS ↔ iOS）を片側だけ変えない。本機能は**契約変更なし**（`plan.md` §2） |
| C-1 | 削除は**ソフトデリートのみ**。物理削除は行わない（`docs/09-roadmap.md:535`「論理削除のみ。物理削除は90日後の `pg_cron`」） |
| C-2 | iOS の書き込み経路は REST DELETE ではなくローカル + `POST /v1/sync/push`（`docs/plans/application-edit/plan.md` D-1 と同じ） |
| C-3 | 一覧画面は `List` ではないためスワイプ削除は使えない（`IdentityListView.swift:118-123`） |
| C-4 | tombstone の payload はスカラー全件 + `deleted_at` を送る既存の `syncPayload()` をそのまま使う。キーの追加・改名をしない |

## 4. スコープ外

- **削除の取り消し / 復元 UI**（Q7）。`docs/01-product-overview.md:250` の「復元可能期間30日」は未実装のまま残る（§7 のリスク R-1）
- 一覧画面からのスワイプ削除（Q1-B）
- FC 会員情報（Membership）単体の削除 UI — 名義削除の連鎖としてのみ扱う。会員情報カードごとの削除ボタンは本計画に含めない
- ツアー / 公演の削除 UI（`DELETE /v1/tours/:id` / `DELETE /v1/events/:id` は BE にあるが導線を作らない）
- 共有ボード（受け取り側）からの削除
- BE の製品コード変更（テスト追加のみ = `plan.md` T7）
- 削除済み名義の**名前**を表示する経路（Q5-B）

## 5. 受入基準

| AC-ID | 基準 | 検証方法 |
|---|---|---|
| AC-DEL-01 | 申込詳細に削除ボタンがあり、押すと確認ダイアログが出る。キャンセルすると何も起きない | 手動 |
| AC-DEL-02 | 申込を削除すると `fetchActive` 相当から消え、その同行者行も `deletedAt` が立つ | XCTest（DataStore） |
| AC-DEL-03 | 申込削除で outbox に `applications` と `applicationCompanions` の両方が積まれる | XCTest（DataStore） |
| AC-DEL-04 | 申込削除後、`ApplicationStore.applications` から当該申込が消え、`writeError` が nil のまま | XCTest（Domain・Fake Repository） |
| AC-DEL-05 | 申込削除で公演・ツアーのレコードは消えない | XCTest（DataStore） |
| AC-DEL-06 | 名義詳細に削除ボタンがあり、確認ダイアログに会員情報 N 件・申込 M 件の実数が入る | 手動 |
| AC-DEL-07 | 名義を削除すると、その名義の会員情報も `deletedAt` が立ち、outbox に `identities` と `memberships` が積まれる | XCTest（DataStore） |
| AC-DEL-08 | 名義削除で、その名義を代表とする申込は残る（`deletedAt == nil`） | XCTest（DataStore） |
| AC-DEL-09 | 名義削除で、削除された membership を `repMembershipID` に持つ未削除の申込が `nil` にクリアされ、当該申込も outbox に積まれる | XCTest（DataStore） |
| AC-DEL-10 | 名義削除後、`IdentityStore.identities` と `memberships` の両方から該当分が消える | XCTest（Domain） |
| AC-DEL-11 | 名義削除後、`expiringMembershipCount` に削除した名義の会員情報が含まれない | XCTest（Domain） |
| AC-DEL-12 | 削除済み名義を代表とする申込の詳細で「削除された名義」と表示され、タップしても遷移しない | 手動 |
| AC-DEL-13 | 削除に失敗（`.notFound`）したとき、画面が閉じずエラーバーが出て一覧の内容が変わらない | XCTest（Domain）+ 手動 |
| AC-DEL-14 | 機内モードで削除 → 一覧から消える。オンライン復帰後、サーバー側でも `deleted_at` が入る | 手動 |
| AC-DEL-15 | 名義を上限（Free 3 件）まで作った状態で 1 件削除すると、新規追加できるようになる | 手動 |
| AC-DEL-16 | 削除後に通知が再スケジュールされ、削除対象の通知が残らない | 手動 |
| AC-DEL-17 | （BE 回帰）`identities` / `memberships` / `applications` の tombstone を含む push が accepted され、名義上限チェックで弾かれない | jest（`sync.service.spec.ts`） |

## 6. 影響範囲

| 層 | 対象 |
|---|---|
| DB | **変更なし** |
| BE | **製品コード変更なし**。`apps/api/src/sync/sync.service.spec.ts` にテスト追加のみ |
| iOS Domain | `Stores/IdentityStore.swift`（削除メソッド + 件数算出 + `expiringMembershipCount` の整合）、`Stores/ApplicationStore.swift`（削除メソッド）、`Repositories.swift`（`delete` の連鎖セマンティクスをコメントで明記）、`Preview/InMemoryRepositories.swift` |
| iOS DataStore | `SwiftDataIdentityRepository.delete`（memberships + rep_membership 参照クリアへ拡張）、`SwiftDataApplicationRepository.delete`（既存のまま） |
| iOS Features | `Detail/IdentityDetailView.swift`、`Detail/ApplicationDetailView.swift` |
| iOS App | 削除後の通知再スケジュール（既存 `NotificationBridge.rescheduleIfAuthorized` を使う。App 層の変更は原則不要） |
| docs | `docs/05-ios-client.md`（削除フロー）、`docs/01-product-overview.md:250`（復元 30 日の未実装を注記）、`docs/09-roadmap.md`（復元 UI を未着手として記載） |

## 7. リスク・既知の不整合

| # | 内容 | 扱い |
|---|---|---|
| R-1 | `docs/01-product-overview.md:250`「削除は全てソフトデリート＋**復元可能期間30日**」に対し、復元 UI も復元 API も存在しない。削除 UI を出すと、この乖離がユーザーに見える形になる | Q7 = 対象外。docs に未実装として明記し、ロードマップへ残す |
| R-2 | `SwiftDataMembershipRepository.delete:64-73` は BE の `memberships.remove:156-165` と違い `rep_membership_id` をクリアしない（**既存の乖離**・BE-9 型「書き込み経路が 2 本あるのに検証/後始末が片方だけ」） | FR-DEL-10 で名義削除の連鎖経路には実装する。会員情報単体削除の経路は現状呼び出し元が無いため、同じ処理を共通化して両方から使う |
| R-3 | ツアー表 / 共有ボードは削除済み名義の現在名を解決して表示し続ける（`tour-matrix.service.ts:104-110`。`repIdentity` に `deletedAt` フィルタが無い） | 仕様として受け入れる（F10）。共有先に「削除したはずの名義名」が出る点は Q6 の回答で再確認 |
| R-4 | 名義を削除しても、その名義だけが使われていたツアー / 公演は残る（孤児ツアー）。BE の `tours.remove` も連鎖しない | 受け入れる。ツアー表は申込から組むため空ツアーは表示されない |
| R-5 | 同期の LWW は「削除より新しい編集が勝つ」（`docs/05-ios-client.md:930`）。別端末で同じ申込を編集中に削除すると、編集の `updated_at` が新しければ削除が取り消される | 既存仕様。本計画では変更しない |
| R-6 | `sync.service.spec.ts` に tombstone push のテストが 1 件も無い。「BE 変更不要」の主張が回帰で守られていない | T7 でテストを追加して主張を固定する |
