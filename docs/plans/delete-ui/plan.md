# delete-ui — Workflow Plan

`requirements.md` の受入基準を実装タスクへ分解する。実装着手前に Q1〜Q9（`questions-requirements.md`）の回答で差分がないか確認すること。

## 0. 現状把握（ギャップ分析）

| 層 | 既にあるもの | 欠けているもの |
|---|---|---|
| DB | 全テーブルに `deleted_at`（`schema.prisma`） | なし（**スキーマ変更なし**） |
| BE REST | `DELETE /v1/identities/:id`（`identities.service.ts:116-129`）/ `DELETE /v1/applications/:id` + companions 連鎖（`applications.service.ts:108-125`）/ `DELETE /v1/memberships/:id` + `rep_membership_id` クリア（`memberships.service.ts:145-166`） | なし（**製品コードの追加実装なし**） |
| BE 同期 | `POST /v1/sync/push` が 6 コレクションの `deleted_at` を受理（`sync-payload.mapper.ts:38,50,56,65,80,88`）。tombstone は名義上限チェックを免除（`sync.service.ts:140-149`）。FK 検証は削除済み親を許容（`sync.service.ts:259-261` のコメント） | **tombstone の回帰テストがゼロ**（`sync.service.spec.ts` に `deleted_at` の記述なし） |
| iOS Domain | `IdentityRepository.delete`（`Repositories.swift:51`）/ `MembershipRepository.delete`（`:58`）/ `ApplicationRepository.delete`（`:79`）。`InMemoryRepositories.swift:36,70,194` に実装あり | **`IdentityStore` / `ApplicationStore` に削除メソッドが無い**。上記 protocol の**呼び出し元がゼロ**（実装済み未配線 = IOS-1） |
| iOS DataStore | `SwiftDataApplicationRepository.delete:194-209`（companions 連鎖 + outbox 2 種、既に BE と等価）/ `SwiftDataIdentityRepository.delete:52-61`（identity 単体のみ）/ `SwiftDataMembershipRepository.delete:64-73` | 名義削除の **memberships 連鎖**と、**`repMembershipID` クリア**（BE `memberships.service.ts:156-165` 相当）が無い |
| iOS Features | `ApplicationDetailView`（編集導線あり `:56-69`）/ `IdentityDetailView` | 削除ボタン・確認ダイアログ・削除済み名義参照の表示（`ApplicationDetailView.swift:134` は「不明 ›」で行き止まりリンク） |
| iOS App | `NotificationScheduler.reschedule(identityStore:applicationStore:)`（`:34-70`）と `NotificationBridge.rescheduleIfAuthorized` | 削除後に呼ぶ配線 |

**結論**: DB 変更ゼロ・BE 製品コード変更ゼロ。不足は **iOS の Store 2 メソッド + 詳細画面 2 つの導線 + 名義削除の連鎖（DataStore）**。

## 1. 設計判断

### D-1 書き込み経路はローカル SSoT + 同期 push（REST DELETE は使わない）

本番構成は `SwiftData*Repository` を注入する（`AppEnvironment.swift`・`docs/plans/application-edit/plan.md` D-1）。削除も同じ経路に乗せ、`deleted_at` 入りの payload を outbox 経由で `POST /v1/sync/push` に送る。

- 却下: `RemoteIdentityRepository` / `RemoteApplicationRepository` の `DELETE /v1/...` を直接叩く。ローカルが SSoT なので二重書き込みになり、オフライン削除（FR-DEL-17）が壊れる。
- 帰結: **BE の DELETE 契約は変更も利用もしない**。BE 側は tombstone push を受ける経路だけが本機能の実行経路（§2）。

### D-2 名義削除の連鎖は Repository の 1 セーブに閉じる（Store でループしない）

`SwiftDataIdentityRepository.delete(id:)` を拡張し、**同一 `ModelContext` / 同一 `save()`** で
①identity の softDelete → ②その identity の未削除 memberships を softDelete → ③削除される membership を `repMembershipID` に持つ未削除 applications をクリア → ④それぞれ outbox へ enqueue、までを行う。

- 手本: `SwiftDataApplicationRepository.delete:194-209` が既に「本体 + 子（companions）を 1 セーブで tombstone 化」を実装している。同じ形にする。
- 却下 a: `IdentityStore` が `membershipRepository.delete(id:)` を件数分ループする。`save()` が N+1 回に割れ、途中失敗で「名義は消えたが会員情報は残る」中途半端な状態が残る（IOS-13 と同型）。
- 却下 b: 会員情報を残して iOS の読み側全部にフィルタを足す（Q3-B）。`expiringMembershipCount:91-97` と `NotificationScheduler:41-49` の 2 箇所だけでは済まず、消し忘れが静かにバグになる。
- 併せて ③ を `SwiftDataMembershipRepository.delete` からも使える private/内部関数として書き、**R-2 の乖離（BE-9 型）を 1 箇所で閉じる**。

### D-3 削除は楽観更新しない

`IdentityStore` の既存の書き込みは「楽観反映 → 失敗したら revert」（`persistUpdate:224-239`）だが、削除は identity + memberships + applications にまたがるため、後付け undo は破綻する（IOS-13）。`ApplicationStore.updateApplication:386-418`（application-edit D-5）と同じく、
**`await` して成功したらローカル配列から取り除き、失敗したら何も変えずエラーを立てる**。

- 削除は SwiftData へのローカル書き込みなので待ち時間は無視できる。楽観更新の利得が無い。

### D-4 削除ボタンは詳細画面の最下部・確認ダイアログ必須

`ApplicationDetailView` は既に右上ツールバーを「編集」で使っている（`:56-69`）ので、削除はツールバーに増やさず**本文最下部の destructive ボタン**に置く。`confirmationDialog` の文言には実データの件数を入れる（FR-DEL-2 / FR-DEL-7）。

- 却下 a: ツールバーの「…」メニューに畳む。タップ数が増えるうえ、名義詳細側には既存メニューが無く 2 画面で形が揃わない。
- 却下 b: 一覧のスワイプ削除（Q1-B）。一覧は `List` ではない（`IdentityListView.swift:118-123`）ため画面構造の作り替えが必要で、削除 UI の付随作業の範囲を超える。

### D-5 削除済み名義の参照は「表示名を出さずリンクを切る」

`IdentityStore.identity(for:)` が nil を返すこと自体が「削除済みまたは未取得」の合図。現状の `?? "不明"` を **「削除された名義」+ 非リンク表示**に変える（FR-DEL-13/14）。

- 却下: 削除済み名義の表示名をローカル DB から引く（Q5-B）。`IdentityRepository.list()` の契約（`deletedAt == nil` で絞る = `SwiftDataIdentityRepository.swift:20`）を広げる必要があり、Store の意味論（`identities` は生きている名義）まで揺らす。

### D-6 削除後は通知を再スケジュールする

`NotificationScheduler.reschedule` は `identityStore.memberships` / `applicationStore.applications` を無条件に走査する（`:41-61`）。Store から消えていれば正しい結果になるので、**削除成功後に `notificationBridge.rescheduleIfAuthorized()` を呼ぶだけでよい**（既存の `AddMembershipView.swift` と同じ使い方）。App 層の変更は不要。

## 2. API 契約

**新規エンドポイントなし。既存契約の変更なし。DB 変更なし。** 実装者はこの節を正とする。

### 使う経路: `POST /v1/sync/push`（既存・変更なし）

```jsonc
{
  "mutations": [
    { "collection": "identities",              "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { /* スカラー全件 + "deleted_at": "<ISO8601>" */ } },
    { "collection": "memberships",             "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { ..., "deleted_at": "<ISO8601>" } },
    { "collection": "applications",            "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { ..., "deleted_at": "<ISO8601>" } },
    { "collection": "application_companions",  "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { ..., "deleted_at": "<ISO8601>" } }
  ]
}
```

- `op` は削除でも **`upsert`**。`sync.service.ts:101` は `upsert` 以外を `SYNC_APPLY_FAILED` で弾く。**`"op": "delete"` を新設しない**
- payload の形は既存の `syncPayload()` が正（`IdentityRecord+SyncPayload.swift:22-24` ほか）。**キーの追加・改名なし**
- `deleted_at` は ISO8601 文字列。`null` は「未削除」を意味するので、削除時に省略しない
- FR-DEL-10 の `rep_membership_id` クリアは `applications` の upsert（`rep_membership_id: null` + `deleted_at: null`）として送る。**削除ではない通常更新**
- サーバー側の受理挙動（変更しない・T7 で固定する）:
  - tombstone の identities は名義上限チェックを免除される（`sync.service.ts:140-149` + `isDeletedPayload`）
  - FK 検証は親の `deletedAt` を見ない（`sync.service.ts:259-261`）ので、削除済み名義を参照する申込 tombstone も通る
  - LWW: サーバーの `updated_at` の方が新しいと `SYNC_LWW_REJECT`（削除が取り消されうる = R-5）

### 使わない経路（契約は現状維持）

| エンドポイント | 状態 |
|---|---|
| `DELETE /v1/identities/:id` | 既存のまま。memberships / applications へ連鎖しない |
| `DELETE /v1/applications/:id` | 既存のまま。companions は連鎖する |
| `DELETE /v1/memberships/:id` | 既存のまま。`rep_membership_id` をクリアする |

## 3. タスク分解

担当は `.claude/rules/02-agents.md` に従う。**BE の製品コード変更は無い**（T7 はテストのみ）。

| # | タスク | 層 / 主な対象 | 担当 | 依存 |
|---|---|---|---|---|
| T1 | `SwiftDataIdentityRepository.delete` を連鎖削除へ拡張（identity + memberships + `repMembershipID` クリア、outbox 3 種、1 セーブ）。`repMembershipID` クリアは `SwiftDataMembershipRepository.delete` からも呼べる共通処理として実装（R-2 を閉じる）。**XCTest 先行（Red→Green）** | `Packages/DataStore/Sources/DataStore/Local` + `DataStore/Tests` | swift-developer | — |
| T2 | `ApplicationRepository.delete` の DataStore テストを追加（既存実装の固定化。companions 連鎖 / outbox 2 種 / tour・event が消えないこと / 削除済み再削除は `.notFound`）。**製品コードは変更しない見込み。差分が出たら報告** | `Packages/DataStore/Tests` | swift-developer | — |
| T3 | `ApplicationStore.deleteApplication(id:)` を追加（D-3 の非楽観パターン。`repository == nil` の Preview 経路はローカル配列から取り除くだけ）。Fake Repository で Store テスト | `Packages/Domain/Sources/Domain/Stores/ApplicationStore.swift` + `Domain/Tests` | swift-developer | — |
| T4 | `IdentityStore.deleteIdentity(id:)` を追加（`repository.delete` 1 回 → 成功したら `identities` と該当 `memberships` をローカル配列から除去）。確認ダイアログ用の件数（会員情報 N / 代表申込 M）は **`ApplicationStore` を参照しない**（相互参照禁止 = `IdentityStore.swift:5-7`）ため、申込件数は View 側で `applicationStore.applications(for:)` から取る。`Repositories.swift:51` の `delete` コメントに連鎖セマンティクスを明記。`InMemoryIdentityRepository.delete` も連鎖させる | `Packages/Domain/Sources/Domain/Stores/IdentityStore.swift`・`Repositories.swift`・`Preview/InMemoryRepositories.swift` + `Domain/Tests` | swift-developer | T1（セマンティクス確定後） |
| T5 | `ApplicationDetailView` に削除導線（最下部 destructive ボタン + `confirmationDialog` + 成功時 `path.removeLast()` + `notificationBridge.rescheduleIfAuthorized()`）。併せて FR-DEL-13/14（代表者・同行者の削除済み名義表示とリンク無効化・`:131-159`） | `Packages/Features/Sources/Features/Detail/ApplicationDetailView.swift` | swift-developer | T3 |
| T6 | `IdentityDetailView` に削除導線（同上 + 件数入りダイアログ文言 FR-DEL-7） | `Packages/Features/Sources/Features/Detail/IdentityDetailView.swift` | swift-developer | T4 |
| T7 | `sync.service.spec.ts` に tombstone push の回帰テストを追加（AC-DEL-17）。**製品コードは変更しない**。変更が必要な事実が見つかったら実装せず報告する | `apps/api/src/sync/sync.service.spec.ts` | nest-developer | — |
| T8 | docs 追従: `docs/05-ios-client.md`（削除フローと削除済み名義の表示規則）、`docs/01-product-overview.md:250`（「復元可能期間30日」は未実装である旨の注記）、`docs/09-roadmap.md`（復元 UI を未着手項目として記載） | `docs/` | swift-developer or メイン | T5・T6 |

### 並列実行可能なタスク

```
[T1] ‖ [T2] ‖ [T3] ‖ [T7]        ← 触るファイルが重ならない
  ↓             ↓
[T4]          [T5]                ← T4 は T1 のセマンティクス確定後
  ↓
[T6]
        ↓
      [T8]
```

- **同一ファイルを 2 人に触らせない**: `SwiftDataIdentityRepository.swift`（T1 のみ）/ `ApplicationStore.swift`（T3 のみ）/ `IdentityStore.swift`（T4 のみ）/ `ApplicationDetailView.swift`（T5 のみ）/ `IdentityDetailView.swift`（T6 のみ）
- T1 と T2 は同じ `DataStore/Tests` 配下に書くため、**テストファイルを分ける**（`SwiftDataIdentityRepositoryDeleteTests.swift` / `SwiftDataApplicationRepositoryDeleteTests.swift`）
- BE（T7）と iOS の並列は可。契約は §2 で確定済み

## 4. 受入基準 → テストケース

| AC-ID | テスト | 種別 / 置き場所 |
|---|---|---|
| AC-DEL-02 | 申込削除で申込と companions の `deletedAt` が立つ | XCTest `DataStore/Tests`（T2） |
| AC-DEL-03 | outbox に `applications` + `applicationCompanions` が積まれる | XCTest `DataStore/Tests`（T2） |
| AC-DEL-05 | 申込削除後も tour / event レコードが残る | XCTest `DataStore/Tests`（T2） |
| AC-DEL-07 | 名義削除で memberships も `deletedAt` が立ち、outbox に `identities` + `memberships` が積まれる | XCTest `DataStore/Tests`（T1） |
| AC-DEL-08 | 名義削除後も、その名義を代表とする申込は `deletedAt == nil` | XCTest `DataStore/Tests`（T1） |
| AC-DEL-09 | `repMembershipID` が nil にクリアされ、当該 application も outbox に積まれる | XCTest `DataStore/Tests`（T1） |
| AC-DEL-19（FR-DEL-19） | 削除済み / 存在しない id の削除は `.notFound` を投げる | XCTest `DataStore/Tests`（T1・T2） |
| AC-DEL-04 | Store から申込が消え `writeError == nil` | XCTest `Domain/Tests`（T3） |
| AC-DEL-13 | Repository が投げると配列が変わらず `writeError` が立つ | XCTest `Domain/Tests`（T3・T4） |
| AC-DEL-10 | `identities` と `memberships` の両方から消える | XCTest `Domain/Tests`（T4） |
| AC-DEL-11 | `expiringMembershipCount` が削除分だけ減る | XCTest `Domain/Tests`（T4） |
| AC-DEL-17 | tombstone push が accepted・名義上限で弾かれない・削除済み親を参照する子 tombstone も通る | jest `sync.service.spec.ts`（T7） |
| AC-DEL-01 / 06 / 12 / 14 / 15 / 16 | 手動確認（§5） | — |

**Red 先行の対象**: T1・T2・T3・T4・T7。実装前に失敗するテストを書く。

## 5. 手動確認手順（iOS）

前提: `make up` でローカル API、シミュレータでサインイン済み、名義 2 件以上（うち 1 件は会員情報 1 件以上 + 申込 1 件以上）、申込 2 件以上。

1. **AC-DEL-01** 申込詳細 → 最下部「この申込を削除」→ ダイアログ →「キャンセル」で何も起きない → 再度「削除」で一覧に戻り、その申込が消えている
2. **AC-DEL-05**（表示側）同じ公演の別申込・ツアー表の見出しが残っている
3. **AC-DEL-06** 名義詳細 → 「この名義を削除」→ ダイアログに「会員情報 N 件」「申込 M 件は残ります」の実数が出る
4. 削除実行 → 名義一覧から消える → ホームの「更新が近い会員情報」件数が減る（AC-DEL-11）
5. **AC-DEL-12** 手順 3 で削除した名義を代表とする申込を開く → 代表者欄が「削除された名義」でタップしても遷移しない。同行者に含まれていた場合は名前が残りリンクだけ死んでいる
6. **AC-DEL-15** 名義を Free 上限（3 件）まで作る → 追加でペイウォールが出ることを確認 → 1 件削除 → 追加できる
7. **AC-DEL-14** 機内モードで申込を 1 件削除 → 一覧から消える → オンライン復帰 → 同期後に `psql` か別端末で `deleted_at` が入っていることを確認
8. **AC-DEL-16** 通知許可済みの状態で、更新日が近い会員情報を持つ名義を削除 → 設定 > 通知（または Xcode の pending requests）で該当通知が消えている
9. **回帰** 申込の追加・編集、名義の追加、会員情報の追加が従来どおり動く

## 6. 検証ゲート

```bash
# iOS ビルド（必須）
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build

# パッケージテスト（T1〜T4 の完了ゲート）
swift test --package-path meigicho/Packages/Domain
swift test --package-path meigicho/Packages/DataStore

# BE（T7）
cd apps/api && npx tsc --noEmit && npm test -- --passWithNoTests && npm run build
```

`project.yml` を触った場合は `xcodegen generate` を忘れない（IOS-8。本計画では触らない想定）。

## 7. 実装時に踏みやすい罠（`feedback_review_patterns.md` から該当分）

| # | 本機能での具体形 |
|---|---|
| IOS-1 / IOS-3 | `IdentityRepository.delete` / `ApplicationRepository.delete` は**実装済みで呼び出し元ゼロ**だった。Store とボタンまで配線して初めて完了。削除ボタンを置いただけ・Store メソッドを足しただけで終わらせない |
| IOS-13 | 削除を楽観反映してから失敗時に「戻す」処理を書かない（D-3）。連鎖対象が複数ある削除では後付け undo が破綻する |
| IOS-5 | `Features` から `DataStore` を import しない。詳細画面が触るのは Store まで |
| IOS-2 | tombstone payload のキー（`deleted_at`）を送り漏らさない。既存 `syncPayload()` を使い、独自の payload 組み立てを新設しない |
| BE-9 | 「同じデータに書き込み経路が 2 本あるのに後始末が片方だけ」。BE `memberships.remove` は `rep_membership_id` をクリアするが iOS 側は未実装（R-2）。名義削除の連鎖で同じ穴を再生産しない |
| BE-2 | `op` に `delete` のような未定義値を送らない。削除も `upsert` + `deleted_at`（§2） |
| BE-4 | ローカルでも所有者・存在確認を省かない（既存 `SwiftDataIdentityRepository.delete:54` の `deletedAt == nil` ガードを踏襲） |

## 8. 委譲プロンプト案（オーケストレーター向け）

いずれも冒頭に「まず `.claude/skills/implementing-robustly/SKILL.md` を読み従う」を入れる。

- **T1 → swift-developer**: 目的（名義削除の連鎖をローカル 1 セーブで実装）/ 対象（`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/DataStore`）/ 手本（`SwiftDataApplicationRepository.delete:194-209` の companions 連鎖）/ 仕様（identity + 未削除 memberships を softDelete、削除される membership を `repMembershipID` に持つ未削除 application を nil クリア、3 種の outbox enqueue、`context.save()` は 1 回）/ **XCTest を先に落としてから実装** / 完了条件（`swift test --package-path .../DataStore`）/ 報告（①変更 ②検証結果 ③残課題、file:line）
- **T3 / T4 → swift-developer**: 契約として本 plan の D-3（非楽観）を書き写す / 既存例（`ApplicationStore.updateApplication:386-418`）/ 制約（`IdentityStore` から `ApplicationStore` を参照しない）/ 完了条件（`swift test --package-path .../Domain`）
- **T5 / T6 → swift-developer**: FR-DEL-1/2/4/6/7/11/13/14/15/18 と §5 の手動確認手順を書き写す / スコープ外（スワイプ削除・復元 UI・会員情報単体の削除ボタン）を明記 / 完了条件（`xcodebuild` BUILD SUCCEEDED + 手動確認手順の報告）
- **T7 → nest-developer**: 対象（`/Users/yuyamorishita/オタ活アプリ/apps/api/src/sync/sync.service.spec.ts`）/ 目的（tombstone push の受理を回帰で固定）/ **製品コードを変更しない・テストのみ。変更が必要な事実を見つけたら実装せず報告** / ケース（①identities tombstone が accepted され `ensureWithinLimit` が呼ばれない ②削除済み identity を参照する applications tombstone が FK 検証を通る ③memberships tombstone が accepted）/ 完了条件（`cd apps/api && npm test && npx tsc --noEmit`）

レビューは実装完了後に**別セッションで** `code-reviewer` を呼び、結果を `docs/plans/delete-ui/review.md` に保存する（`.claude/rules/04-review.md`）。
