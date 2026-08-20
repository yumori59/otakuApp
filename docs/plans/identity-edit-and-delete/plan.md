# identity-edit-and-delete — Workflow Plan

`requirements.md` の受入基準を実装タスクへ分解する。着手前に `questions-requirements.md` QE1〜QE9 と
`docs/plans/delete-ui/questions-requirements.md` Q1〜Q9（2026-08-20 確定）に差分が出ていないか確認すること。

**本計画は `docs/plans/delete-ui/`（未実装）を包含する。** 削除の要件・設計判断・タスク（T1〜T8）は
delete-ui 側が正で、本ファイルでは**再定義せず、実行順とファイル占有だけを統合する**（§4）。

## 1. 現状把握（ギャップ分析）

| 層 | 既にあるもの | 欠けているもの |
|---|---|---|
| DB | `identities` / `memberships` の全フィールドが可変（`schema.prisma:103-124`） | なし（**スキーマ変更なし**） |
| BE REST | `PATCH /v1/identities/:id`（7 項目・`update-identity.dto.ts`）/ `PATCH /v1/memberships/:id`（8 項目・`update-membership.dto.ts`） | なし（**製品コードの追加実装なし**） |
| BE 同期 | `POST /v1/sync/push` が `identities` / `memberships` の upsert を受理（`sync-payload.mapper.ts:29-49`）。既存行の更新は名義上限チェックを素通りする（`identities.service.ts:141-144`） | 「上限到達済みユーザーが既存名義を編集できる」ことの**回帰テストが無い**。同期 push には**フィールド単位の検証が無い**（`sync/dto/sync.dto.ts:29-31`・R-1。本計画では直さない） |
| iOS Domain | `IdentityPatch` 7 項目 / `MembershipPatch` 8 項目（`Patches.swift:4-27`）。`IdentityRepository.update` / `MembershipRepository.update`（`Repositories.swift:50,57`）。差分計算を純粋関数に置く前例 `ApplicationEditPlanner` | 名義・会員情報の**差分計算の純粋関数が無い**。`IdentityStore` に `displayName` / `relation` / `joinedOn` を書く口が無い（あるのは色 `:146` / 備考 `:160` / 共有 `:174`）。**会員情報を更新・削除する口はゼロ**（`MembershipRepository.update` は呼び出し元ゼロ = IOS-1） |
| iOS DataStore | `SwiftDataIdentityRepository.update:40-50`（削除済みは `.notFound`）/ `SwiftDataMembershipRepository.update:45-62`（`identity_id` 付け替え時に所有・生存を検証）/ `.delete:64-73` | `update` 2 本の**回帰テストが無い**。`SwiftDataMembershipRepository.delete` が `rep_membership_id` をクリアしない（**delete-ui T1 が閉じる**・delete-ui R-2） |
| iOS Features | `AddIdentityView`（5 項目）/ `AddMembershipView`（4 項目）/ `IdentityDetailView`（インライン編集 3 経路）。create/edit 兼用フォームの前例 `ApplicationFormView(mode:)` | 編集画面そのもの。`AppSheet` に `editIdentity` / `editMembership` が無い（`AppRoute.swift:18-42`）。会員情報カードがタップ不可（`IdentityDetailView.swift:123-131`） |
| iOS テスト基盤 | 広告禁止画面のソース走査テストが**2 パッケージに二重に**存在し、`Forms/Add*View.swift` のパスをハードコードしている | 抽出後の新ファイル（`IdentityFormView.swift` / `MembershipFormView.swift`）を**両方のリストに足さないと、フォーム本体がゲートから外れる**（§5 の罠） |

**結論**: DB 変更ゼロ・BE 製品コード変更ゼロ。不足は **iOS の縦串（Domain の差分計算 → Store の口 → フォームの edit モード → 詳細画面の導線）**だけ。

## 2. 設計判断

### D-1 書き込み経路はローカル SSoT + 同期 push（REST PATCH は使わない）

本番構成は `SwiftData*Repository` を注入する。編集も既存の `repository.update(id:patch:)` に乗せ、
outbox 経由で `POST /v1/sync/push` に送る。

- 却下: `RemoteIdentityRepository` の `PATCH /v1/identities/:id` を直接叩く。ローカルが SSoT なので二重書き込みになり、オフライン編集（FR-IE-11）が壊れる。
- 前例: `application-edit/plan.md` D-1 / `delete-ui/requirements.md` C-2。**この 3 計画で経路を揃える**。
- 帰結: **BE の PATCH 契約は変更も利用もしない**。

### D-2 名義編集に `updateScoped` 相当の新 protocol メソッドを足さない

申込編集は tour + event + application の 3 レコードにまたがるため `ApplicationRepository.updateScoped`
を新設した（`Repositories.swift:78-86`）。**名義編集・会員情報編集は 1 レコードで完結する**ので、
既存の `update(id:_ patch:)` をそのまま使う。

- 却下: 対称性のために `IdentityRepository.updateScoped` を足す。protocol・SwiftData・InMemory・Remote の 4 箇所が増えるだけで、1 レコードの更新に何も足さない。
- 帰結: **`Repositories.swift` は本計画で変更しない**（delete-ui T4 のコメント追記のみ）。

### D-3 差分計算は `Domain` の純粋関数に置く

`IdentityEditPlanner.makePatch(current:input:) -> IdentityPatch` と
`MembershipEditPlanner.makePatch(current:input:) -> MembershipPatch` を新設し、XCTest で Red→Green。

責務:
1. trim（表示名・FC 名・メモ・下 4 桁）
2. **現在値と同じなら `.unchanged`**（キーごと送らない）
3. **「未設定にする」は `.set(nil)`**（`joinedOn` / `renewalOn` / `memberNoLast4` / `feeYen`）
4. **全項目 `.unchanged` なら「変更なし」を呼び出し側へ伝える**（`IdentityPatch` は `Equatable` なので `patch == IdentityPatch()` で判定できる）
5. **ユーザーが触っていない `relation` は `.unchanged`**（未知 raw の書き潰し防止・QE8-A / R-2）

- 却下: View の `save()` 内で `IdentityPatch` を組み立てる。テスト不能になり AC-IE-02〜06 が全部手動確認に落ちる（`application-edit/plan.md` D-2 と同じ理由）。
- 前例: `Domain/Sources/Domain/Models/ApplicationEditPlanner.swift`。

### D-4 「無変更なら送らない」を Store で強制する

`IdentityRecord.apply(patch:)` は `.unchanged` しか含まない patch でも無条件に `markDirty` して
`updatedAt` を進め、outbox に積む（`IdentityRecord+Mapping.swift:34-43` + `SwiftDataIdentityRepository.swift:46`）。
そのため **Store が「変更なし」を検出したらリポジトリを呼ばない**。

- 根拠: 既存の `IdentityStore.updateIdentityColor:149` が `guard previous != colorHex else { return }` で同じ予防をしている。
- 効果: 「開いて閉じただけ」で `updated_at` が進み、別端末の未送信編集が LWW で負ける事故を防ぐ。
- 却下: `apply(patch:)` 側を「`.unchanged` だけなら markDirty しない」に変える。pull / 削除など他の呼び出し元の意味論に波及するため、呼び出し側で止める。

### D-5 保存は楽観更新しない。既存のインライン編集 3 経路は触らない

編集フォームは 4〜5 フィールドにまたがるため、失敗時の「後付け undo」を書かない（IOS-13）。
`isSaving` → `await` → 成功でリポジトリの戻り値を反映して dismiss、失敗はシートを開いたままエラー表示。

- 前例: `ApplicationStore.updateApplication:386-418`（application-edit D-5）/ `delete-ui/plan.md` D-3。
- **`updateIdentityColor` / `updateIdentityNote` / `toggleHistoryVisible` は楽観更新のまま変えない**（NFR-2）。1 フィールドの巻き戻しは成立しており、触ると回帰リスクだけが増える。
- 2 経路併存の安全性: `Patchable` により未操作フィールドはキーごと送られず、`record.apply(patch:)` も `.set` だけを書く。**古いフォームが他フィールドを書き潰す事故は起きない**（R-4）。

### D-6 導線: 名義は toolbar「編集」、会員情報はカードタップ、削除の位置は delete-ui のまま

| 対象 | 編集の導線 | 削除の導線 |
|---|---|---|
| 名義 | `IdentityDetailView` の `topBarTrailing`「編集」（`ApplicationDetailView.swift:56-69` と同形） | 詳細**本文最下部**の destructive ボタン（delete-ui D-4・変更しない） |
| 申込 | 既存（実装済み） | 詳細**本文最下部**（delete-ui D-4） |
| 会員情報 | 会員情報カードをタップ | **編集シート最下部**の destructive ボタン（詳細画面が存在しないため） |

- `MembershipCard` は `DesignSystem` の表示専用コンポーネント（`FormComponents.swift:221-229`）。**API を変えず**、Features 側で `Button` + `.contentShape(Rectangle())` + `.buttonStyle(.plain)` で包む（NFR-4 / IOS-5）。
- 却下 a: 削除をツールバーに寄せる。編集と隣接して誤タップの導線になる。
- 却下 b: 一覧のスワイプ編集。一覧は `List` ではない（`IdentityListView.swift:118-123`）ため画面構造の作り替えになる。

### D-7 フォームは create/edit 共用に統合し、リファクタと機能追加を分ける

`IdentityFormView(mode:)` / `MembershipFormView(mode:)` に統合する。ただし
1. **振る舞い不変の抽出**（TE-4 / TE-5）
2. **edit モード追加**（TE-6）
に分割し、1 単体で「追加フローが従来どおり」をレビュー・確認できるようにする。

- 前例: `AddApplicationView.swift` は抽出後、`ApplicationFormView(mode: .create)` を返すだけの**薄いラッパとして残っている**。同じ形にする。
- **ファイルを消してはいけない**: `Forms/AddIdentityView.swift` / `Forms/AddMembershipView.swift` は
  広告禁止画面のソース走査テストが**絶対パスで参照している**（`AdSlotForbiddenScreensTests.swift:14-15` /
  `AdGatekeeperTests.swift:140-141`）。消すと `try String(contentsOf:)` が throw してテストが落ちる。
- **新ファイルを両リストに足す**: `Forms/IdentityFormView.swift` / `Forms/MembershipFormView.swift` を
  上記 2 ファイルのリストに追加する。足さないと、フォーム本体が広告ゲートの走査対象から外れる
  （抽出時に `Forms/ApplicationFormView.swift` を両方へ足した前例がある = 同 `:17` / `:143`）。
- 却下: `EditIdentityView` を別実装。5 項目 + 4 項目が二重管理になり必ずドリフトする（application-edit D-4 と同じ判断）。

### D-8 create 専用の副作用を edit へ漏らさない

| 副作用 | ファイル | edit での扱い |
|---|---|---|
| 保存後に会員情報追加シートへ進む（`onSaved`） | `AddIdentityView.swift:53,88` / `HomeView.swift:23` ほか | **edit では発火させない**（`mode` で分岐。`onSaved` は `.create` のみが持つ） |
| 初回の通知許可シート | `AddMembershipView.swift:79-85,100-104` | **edit では出さない**（FR-IE-20 / AC-IE-16） |
| `onAppear` で今日・既定カラーを代入 | `AddIdentityView.swift:71-74` / `AddMembershipView.swift:76-78` | **edit では現在値を代入**。特に `joinedOn` が nil の名義で `today` を入れてはいけない（FR-IE-5 / AC-IE-04） |

`ApplicationFormView.swift:37` の `@State private var eventOn: Date?`（nil = ユーザー未操作）と
同じ手法を `joinedOn` / `renewalOn` に使う。

## 3. API 契約

**新規エンドポイントなし。既存契約の変更なし。DB 変更なし。** 実装者はこの節を正とする。

### 使う経路: `POST /v1/sync/push`（既存・変更なし）

```jsonc
{
  "mutations": [
    { "collection": "identities",  "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { /* 下表・スカラー全件 */ } },
    { "collection": "memberships", "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { /* 下表・スカラー全件 */ } },
    // 会員情報削除に伴う rep_membership_id クリア（削除ではない通常更新）
    { "collection": "applications", "id": "<uuid>", "op": "upsert", "updated_at": "<ISO8601>", "payload": { "...": "...", "rep_membership_id": null, "deleted_at": null } }
  ]
}
```

#### `identities` の payload キー（`IdentityRecord+SyncPayload.swift:7-26` が正）

| キー | 型 | 備考 |
|---|---|---|
| `display_name` | string | 空文字を送らない（iOS 側でガード。`sync/push` は検証しない = R-1） |
| `relation` | string | `self` / `family` / `friend` / `other`（`create-identity.dto.ts` の `IDENTITY_RELATIONS`）。**未操作なら現在の raw をそのまま送る**（QE8-A） |
| `color` | string | `#RRGGBB`（6 桁 hex） |
| `joined_on` | string \| null | `"YYYY-MM-DD"`・JST 基準（`APIDateFormat.dateOnlyString`） |
| `note` | string \| null | 空文字は `null` として送る（既存 `syncPayload()` の挙動） |
| `history_visible` | bool | 編集フォームからは変更しない（詳細のスイッチのまま） |
| `sort_order` | number | 編集フォームからは変更しない |
| `deleted_at` | string \| null | 編集では常に `null` |

#### `memberships` の payload キー（`MembershipRecord+SyncPayload.swift:30-41` が正）

| キー | 型 | 備考 |
|---|---|---|
| `identity_id` | uuid string | 編集で付け替えない（フォームに項目が無い） |
| `fan_club_name_raw` | string | 空文字を送らない |
| `member_no_last4` | string \| null | 1〜4 文字の英数のみ。**全桁を送らない**（C5 / FR-IE-23） |
| `rank` | string \| null | フォームに無い。**現在値をそのまま送る**（消さない = FR-IE-19 / AC-IE-11） |
| `renewal_on` | string \| null | `"YYYY-MM-DD"`・JST 基準 |
| `fee_yen` | number \| null | |
| `auto_renew` | bool | フォームに無い。現在値をそのまま送る |
| `note` | string \| null | フォームに無い。現在値をそのまま送る |
| `deleted_at` | string \| null | 会員情報削除時のみ ISO8601 |

- `op` は削除でも **`upsert`**。`sync.service.ts:101` は `upsert` 以外を `SYNC_APPLY_FAILED` で弾く。**`"op": "delete"` を新設しない**（BE-2）
- **payload は差分ではなくスカラー全件**。`Patchable` の「送らない」が効くのは**ローカル書き込みまで**で、push はレコード全体を送る（R-3）。だから FR-IE-19 は「フォームに無い項目もレコードから読んでそのまま載る」ことで満たされる
- 既存行の `identities` upsert は名義上限チェックを通過する（`identities.service.ts:141-144` の early return）。**この挙動に依存する**ので TE-8 で回帰テストを置く

### 使わない経路（契約は現状維持）

| エンドポイント | 状態 |
|---|---|
| `PATCH /v1/identities/:id` | 既存のまま。`display_name` は 1〜60 文字、`relation` は `@IsIn` |
| `PATCH /v1/memberships/:id` | 既存のまま。`identity_id` 変更時も所有検証 |
| `DELETE /v1/memberships/:id` | 既存のまま。`rep_membership_id` をクリアする |

## 4. タスク分解と実行順（delete-ui 統合）

担当は `.claude/rules/02-agents.md` に従う。**BE の製品コード変更は無い**（BE はテストのみ）。
`dT*` = `docs/plans/delete-ui/plan.md` のタスク（内容は同ファイルが正）。`TE-*` = 本計画の新規タスク。

| # | タスク | 層 / 主な対象 | 担当 | 依存 |
|---|---|---|---|---|
| dT1〜dT8 | `delete-ui/plan.md` §3 のとおり | — | — | 同計画 |
| TE-1 | 差分計算の純粋関数を新設: `IdentityEditFormInput` / `IdentityEditPlanner` / `MembershipEditFormInput` / `MembershipEditPlanner`。trim・`.unchanged` 判定・`.set(nil)`・「全件無変更」判定・未操作 `relation` の保持。**XCTest 先行（Red→Green）** | `Packages/Domain/Sources/Domain/Models`（新規ファイル）+ `Domain/Tests`（新規ファイル） | swift-developer | — |
| TE-2 | DataStore の回帰テストを追加: `SwiftDataIdentityRepository.update` / `SwiftDataMembershipRepository.update` / `SwiftDataMembershipRepository.delete`。**製品コードは変更しない見込み。差分が要ると分かったら実装せず報告** | `Packages/DataStore/Tests`（新規ファイル） | swift-developer | dT1（`repMembershipID` クリアの共通処理が入ってから） |
| TE-3 | `IdentityStore` に `updateIdentity(id:input:)` / `updateMembership(id:input:)` / `deleteMembership(id:)` を追加（D-4 の無変更スキップ + D-5 の非楽観）。Fake Repository で Store テスト | `Domain/Sources/Domain/Stores/IdentityStore.swift` + `Domain/Tests` | swift-developer | TE-1・**dT4（同一ファイル）** |
| TE-4 | `IdentityFormView(mode:)` を `AddIdentityView` から抽出（**振る舞い不変**）。`AddIdentityView` は薄いラッパとして残す。**広告禁止画面リスト 2 本に `Forms/IdentityFormView.swift` を追加** | `Features/Sources/Features/Forms`・`DesignSystem/Tests/.../AdSlotForbiddenScreensTests.swift`・`Domain/Tests/.../AdGatekeeperTests.swift` | swift-developer | — |
| TE-5 | `MembershipFormView(mode:)` を `AddMembershipView` から抽出（**振る舞い不変**・通知許可シートの発火条件を変えない）。**同 2 本に `Forms/MembershipFormView.swift` を追加** | 同上 | swift-developer | **TE-4（テスト 2 ファイルが同一）** |
| TE-6 | edit モード + 配線: `AppSheet.editIdentity(id:)` / `.editMembership(id:)`（`AppRoute.swift`）→ `SheetContentView` → `IdentityDetailView` の「編集」ツールバー + 会員情報カードのタップ化。D-8 の create 専用副作用の分離 | `Features/Sources/Features/Navigation/AppRoute.swift`・`Forms/SheetContentView.swift`・`Forms/*FormView.swift`・`Detail/IdentityDetailView.swift` | swift-developer | TE-3・TE-4・TE-5・**dT6（`IdentityDetailView.swift` が同一）** |
| TE-7 | 会員情報の単体削除 UI: `MembershipFormView` 最下部の destructive ボタン + `confirmationDialog` + 成功で dismiss + `notificationBridge.rescheduleIfAuthorized()` | `Features/Sources/Features/Forms/MembershipFormView.swift` | swift-developer | TE-6・**dT1** |
| TE-8 | BE 回帰テスト（**dT7 と同一ファイルなので 1 タスクに束ねて 1 人に出す**）: ①dT7 の tombstone push ②**名義上限に達したユーザーの既存 `identities` upsert が accepted され `PLAN_LIMIT_IDENTITY` にならない**（AC-IE-20） ③`memberships` upsert が accepted。**製品コードは変更しない** | `apps/api/src/sync/sync.service.spec.ts` | nest-developer | — |
| TE-9 | docs 追従（**dT8 と束ねる**）: `docs/09-roadmap.md` に **0-5b 名義編集 / 0-6b 会員情報編集**を 0-11b（`:80`）と同じ形で追記 + 復元 UI を未着手として記載 / `docs/05-ios-client.md` に編集・削除フローと新フォーム画面 / `docs/01-product-overview.md`（`:250` の復元 30 日が未実装である注記 + 「名義・会員情報は後から編集できる」） | `docs/` | swift-developer or メイン | TE-6・dT6 |

### 並列実行可能なタスク（統合実行順）

```
Wave 1  [dT1] ‖ [dT2] ‖ [dT3] ‖ [dT7+TE-8] ‖ [TE-1] ‖ [TE-4]
                                                          ↓
Wave 2  [dT4] ‖ [dT5] ‖ [TE-2]                        ‖ [TE-5]
          ↓
Wave 3  [dT6] ‖ [TE-3]
                  ↓
Wave 4        [TE-6]
                  ↓
Wave 5        [TE-7]
                  ↓
Wave 6        [dT8+TE-9]
```

- **同一ファイルを 2 人に触らせない**（衝突が起きる実ファイル）:

| ファイル | 触るタスク | 順序 |
|---|---|---|
| `Domain/Stores/IdentityStore.swift` | dT4 → TE-3 | **直列必須** |
| `Features/Detail/IdentityDetailView.swift` | dT6 → TE-6 | **直列必須** |
| `Features/Forms/SheetContentView.swift` | TE-6 のみ | 単独 |
| `Features/Navigation/AppRoute.swift` | TE-6 のみ | 単独 |
| `Features/Forms/MembershipFormView.swift` | TE-5 → TE-6 → TE-7 | **直列必須** |
| `DesignSystem/Tests/.../AdSlotForbiddenScreensTests.swift` | TE-4 → TE-5 | **直列必須** |
| `Domain/Tests/.../AdGatekeeperTests.swift` | TE-4 → TE-5 | **直列必須** |
| `DataStore/Local/SwiftDataIdentityRepository.swift` | dT1 のみ | 単独 |
| `DataStore/Local/SwiftDataMembershipRepository.swift` | dT1 のみ（TE-2 はテストのみ） | 単独 |
| `Domain/Preview/InMemoryRepositories.swift` | dT4 のみ | 単独 |
| `apps/api/src/sync/sync.service.spec.ts` | dT7 + TE-8（**束ねる**） | 単独 |
| `docs/` | dT8 + TE-9（**束ねる**） | 単独 |

- BE（dT7+TE-8）と iOS の並列は可。契約は §3 で確定済み。
- テストファイルは新規作成し、既存ファイルに相乗りしない（`IdentityEditPlannerTests.swift` / `MembershipEditPlannerTests.swift` / `SwiftDataIdentityRepositoryUpdateTests.swift` / `SwiftDataMembershipRepositoryEditTests.swift`）。

## 5. 受入基準 → テストケース

| AC-ID | テスト | 種別 / 置き場所 |
|---|---|---|
| AC-IE-02 | 表示名だけ変更 → `displayName` のみ `.set`、他は `.unchanged` | XCTest `Domain/Tests`（TE-1） |
| AC-IE-03 | 全項目無変更 → `patch == IdentityPatch()`。Store が Fake Repository を呼ばない | XCTest `Domain/Tests`（TE-1 + TE-3） |
| AC-IE-04 | `joinedOn == nil` の名義で日付未操作 → `.unchanged`（`.set(today)` にならない） | XCTest `Domain/Tests`（TE-1） |
| AC-IE-05 | 入会日を未設定へ → `.set(nil)` | XCTest `Domain/Tests`（TE-1） |
| AC-IE-06 | `relation` 未操作 → `.unchanged`。未知 raw の行でも `"other"` を書き戻さない | XCTest `Domain/Tests`（TE-1） |
| AC-IE-12 | 更新日を未設定へ → `renewalOn` が `.set(nil)`、ローカル行が null | XCTest `Domain/Tests`（TE-1）+ `DataStore/Tests`（TE-2） |
| AC-IE-08 | 保存成功で `IdentityStore.identities` が更新され `actionError == nil` | XCTest `Domain/Tests`（TE-3） |
| AC-IE-09 | Repository が投げると配列が変わらず `actionError` が立つ | XCTest `Domain/Tests`（TE-3） |
| AC-IE-10 | 名義更新で SwiftData 行が変わり、outbox に `identities` が 1 件、`updatedAt` が進む | XCTest `DataStore/Tests`（TE-2） |
| AC-IE-11 | `rank` / `autoRenew` / `note` が保持される（FC 名だけ変更） | XCTest `DataStore/Tests`（TE-2） |
| AC-IE-13 | 会員情報更新で outbox に `memberships` が 1 件 | XCTest `DataStore/Tests`（TE-2） |
| AC-IE-14 | 会員情報削除で `deletedAt` が立ち、`repMembershipID` が nil にクリアされ、当該 application も outbox に積まれる | XCTest `DataStore/Tests`（TE-2・dT1 の共通処理を検証） |
| AC-IE-15 | 会員情報削除後も名義・申込は残る | XCTest `DataStore/Tests`（TE-2） |
| AC-IE-18 | 削除済み会員情報の編集は `.notFound`、新規行を作らない | XCTest `DataStore/Tests`（TE-2） |
| AC-IE-20 | 名義上限到達済みユーザーの既存 `identities` upsert が accepted（`PLAN_LIMIT_IDENTITY` にならない） | jest `sync.service.spec.ts`（TE-8） |
| AC-IE-01 / 07 / 16 / 17 / 19 / 21 / 22 | 手動確認（§6） | — |
| AC-IE-23 | `delete-ui/plan.md` §4 の表に従う | 同計画 |

**Red 先行の対象**: TE-1・TE-2・TE-3・TE-8。実装前に失敗するテストを書く。
TE-4 / TE-5 は振る舞い不変のリファクタなので新規テストは不要だが、**広告ゲートの 2 テストが緑のままであること**が完了条件。

## 6. 手動確認手順（iOS）

前提: `make up` でローカル API、シミュレータでサインイン済み、名義 2 件以上（うち 1 件は会員情報 2 件以上・申込 1 件以上）。

1. **AC-IE-01** 名義詳細 → 右上「編集」→ 5 項目すべてに現在値。キャンセルで何も変わらない
2. **AC-IE-07** 氏名を空白のみにすると保存ボタンが無効
3. 氏名を変更して保存 → シートが閉じ、詳細・名義一覧・ホームの表示名が変わる
4. **AC-IE-21** その名義を代表とする過去の申込詳細・ツアー表・共有プレビューの代表者名も新しい名前になっている
5. **AC-IE-03** もう一度「編集」を開き、何も変えずに保存 → 閉じるだけ（同期バナーが出ない = outbox に積まれていない）
6. **AC-IE-04** 入会日が未設定の名義（`psql` で `joined_on` を null にするか、pull で作る）を編集 → 日付に触れず保存 → 未設定のまま
7. **AC-IE-22**（回帰）名義詳細のカラーピッカー・備考インライン編集・共有スイッチが従来どおり動く。名義追加 → 保存後に会員情報追加シートへ進む
8. **AC-IE-16** 会員情報カードをタップ → 編集シート（**通知許可シートが出ない**）。FC 名を変更して保存 → カードの表示が変わる
9. **AC-IE-11**（表示側）`rank` / メモを持つ会員情報を編集して保存 → `psql` かログで値が消えていないことを確認
10. **AC-IE-17** 更新日を変更して保存 → Xcode の pending notification requests で古い日付の通知が消えている
11. **AC-IE-14/15** 会員情報編集シート最下部「この会員情報を削除」→ ダイアログ → 削除 → カードが消える。名義と申込は残る。その会員情報を代表会員情報にしていた申込を開いても壊れない
12. **AC-IE-19** 機内モードで名義名を変更 → 反映される → オンライン復帰 → 同期後に `psql` か別端末でサーバー反映を確認
13. **AC-IE-20** Free 上限（3 件）まで名義を作った状態で既存名義を編集して保存 → 成功する（ペイウォールが出ない）
14. **AC-IE-09** API を落とすのではなく**ローカルで失敗する条件**（削除済み名義を別端末で消した後に編集）で保存 → シートが閉じずエラーが出る
15. **delete-ui** の手動確認は `delete-ui/plan.md` §5 のとおり実施する

## 7. 検証ゲート

```bash
# iOS ビルド（必須）
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build

# パッケージテスト（TE-1〜TE-5 の完了ゲート）
swift test --package-path meigicho/Packages/Domain
swift test --package-path meigicho/Packages/DataStore
swift test --package-path meigicho/Packages/DesignSystem   # 広告禁止画面リスト（TE-4/TE-5）

# BE（TE-8）
cd apps/api && npx tsc --noEmit && npm test -- --passWithNoTests && npm run build
```

`project.yml` を触った場合は `xcodegen generate` を忘れない（IOS-8。本計画では触らない想定。
**新規 Swift ファイルの追加だけなら再生成は不要**だが、追加後に上記 `xcodebuild` が通ることを必ず確認する）。

## 8. 実装時に踏みやすい罠（`feedback_review_patterns.md` から該当分）

| # | 本機能での具体形 |
|---|---|
| IOS-1 / IOS-3 | `MembershipRepository.update` は**実装済みで呼び出し元ゼロ**。Store とフォームとカードのタップまで配線して初めて完了。Store メソッドを足しただけ・フォームを作っただけで終わらせない |
| IOS-1（変種） | `Forms/Add*View.swift` を消すと広告禁止画面テストが `try String(contentsOf:)` で落ちる。**薄いラッパとして残す**。逆に新ファイルをリストへ足し忘れると、フォーム本体がゲートから外れて静かに穴が開く（D-7） |
| IOS-13 | 保存失敗時の「後付け undo」を書かない（D-5）。既存の楽観更新 3 経路は**触らない** |
| IOS-5 | `Features` から `DataStore` を import しない。フォームが触るのは `IdentityStore` まで。`MembershipCard`（DesignSystem）の API を変えない |
| IOS-2 | 同期 payload のキーを増やさない・改名しない。`rank` / `auto_renew` / `note` は**フォームに無くてもレコードから載る**（§3） |
| BE-2 | 未操作の `relation` を `.other` にフォールバックして書き戻さない（QE8-A / R-2）。`IdentityRecord.relation` の getter は `?? .other` する（`IdentityRecord.swift:57-59`） |
| BE-9 | 「同じデータに書き込み経路が 2 本あるのに片方だけ」。①`PATCH` は検証するが `sync/push` は検証しない（R-1・本計画では iOS 側でガード） ②`memberships.remove` は `rep_membership_id` をクリアするが iOS 側は未実装（dT1 が閉じる。TE-7 は**その共通処理を呼ぶ**。独自に書き直さない） |
| BE-4 | ローカルでも存在・生存確認を省かない（`SwiftDataIdentityRepository.update:42` / `SwiftDataMembershipRepository.update:47` の `deletedAt == nil` ガードを踏襲） |
| — | date-only は `APIDateFormat`（JST 基準・`Core/APIDateFormat.swift:15-38`）を使う。`DateFormatter` を新設しない |

## 9. 委譲プロンプト案（オーケストレーター向け）

いずれも冒頭に「まず `.claude/skills/implementing-robustly/SKILL.md` を読み従う」を入れ、
リポジトリ絶対パス `/Users/yuyamorishita/オタ活アプリ` を書く。報告は日本語で ①変更ファイル ②実行した検証コマンドと結果 ③残課題（file:line 付き）。

- **TE-1 → swift-developer**: 目的（名義・会員情報の編集差分を純粋関数化）/ 対象（`meigicho/Packages/Domain`）/ 手本（`Domain/Sources/Domain/Models/ApplicationEditPlanner.swift`）/ 仕様（本 plan D-3 の 5 責務を書き写す。特に「未操作は `nil` で表現し `.unchanged` にする」「全件無変更は `patch == IdentityPatch()` で判定できるようにする」）/ **XCTest を先に落としてから実装** / 完了条件（`swift test --package-path .../Domain`）
- **TE-2 → swift-developer**: 対象（`meigicho/Packages/DataStore/Tests`）/ 目的（既存 `update` / `delete` の挙動を回帰で固定）/ **製品コードを変更しない。変更が必要な事実を見つけたら実装せず報告** / ケース（AC-IE-10/11/12/13/14/15/18）/ 前提（dT1 完了済み・`repMembershipID` クリアの共通処理がある）
- **TE-3 → swift-developer**: 契約として D-4（無変更ならリポジトリを呼ばない）と D-5（非楽観）を書き写す / 既存例（`ApplicationStore.updateApplication:386-418`・`IdentityStore.updateIdentityColor:146-158`）/ 制約（**既存の楽観更新 3 経路を変えない**・`IdentityStore` から `ApplicationStore` を参照しない）/ 完了条件（`swift test --package-path .../Domain`）
- **TE-4 / TE-5 → swift-developer（直列）**: 目的（**振る舞い不変**の抽出）/ 手本（`Features/Sources/Features/Forms/AddApplicationView.swift` の薄いラッパ + `ApplicationFormView.swift:11-19` の `mode`）/ **必須**（旧ファイルを消さない・新ファイルパスを `DesignSystem/Tests/DesignSystemTests/AdSlotForbiddenScreensTests.swift` と `Domain/Tests/DomainTests/AdGatekeeperTests.swift` の両リストへ追加）/ 完了条件（`xcodebuild` BUILD SUCCEEDED + `swift test --package-path .../Domain` と `.../DesignSystem`）
- **TE-6 / TE-7 → swift-developer（直列）**: FR-IE-1〜23 と D-6 / D-8 と §6 の手動確認手順を書き写す / スコープ外（共有スイッチの移動・インライン編集の撤去・`rank`/`auto_renew`/`note` の追加・スワイプ編集・復元 UI）を明記 / 制約（`MembershipCard` の API を変えない・`Features` から `DataStore` を import しない）/ 完了条件（`xcodebuild` BUILD SUCCEEDED + 手動確認手順の報告）
- **dT7+TE-8 → nest-developer**: 対象（`apps/api/src/sync/sync.service.spec.ts`）/ **製品コードを変更しない・テストのみ。変更が必要な事実を見つけたら実装せず報告** / ケース（①identities tombstone が accepted され `ensureWithinLimit` が呼ばれない ②削除済み identity を参照する applications tombstone が FK 検証を通る ③memberships tombstone が accepted ④**上限到達済みユーザーの既存 identities upsert が accepted**）/ 完了条件（`cd apps/api && npx tsc --noEmit && npm test && npm run build`）

レビューは実装完了後に**別セッションで** `code-reviewer` を呼び、結果を `docs/plans/identity-edit-and-delete/review.md` に保存する（`.claude/rules/04-review.md`）。
delete-ui 分の差分もこのレビューに含める（同計画は単独でレビューされていない）。
