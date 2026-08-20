# identity-edit-and-delete + delete-ui — コードレビュー結果

- 日付: 2026-08-20
- レビュー対象: 作業ツリーの全差分（未コミット。`git status` 基準）
- 参照した正: `docs/plans/identity-edit-and-delete/plan.md` / `docs/plans/delete-ui/plan.md` /
  `.claude/rules/04-review.md` / `.claude/rules/feedback_review_patterns.md`
- レビュアー: code-reviewer（実装者とは別セッション）

## レビュー結果サマリ

- 重大: 1 件
- 中: 3 件
- 軽微/提案: 6 件

## 検証ゲート実行結果（全て緑）

| コマンド | 結果 |
|---|---|
| `swift test --package-path meigicho/Packages/Domain` | **263 tests, 0 failures** |
| `swift test --package-path meigicho/Packages/DataStore` | **50 tests, 0 failures** |
| `swift test --package-path meigicho/Packages/DesignSystem` | **1 test, 0 failures** |
| `xcodebuild ... build` | **BUILD SUCCEEDED**（warning 0 件） |
| `cd apps/api && npx tsc --noEmit` | exit 0 |
| `cd apps/api && npm test -- --passWithNoTests` | **87 suites / 902 tests, 0 failures** |
| `cd apps/api && npm run build` | exit 0 |

---

## 重大 (Must Fix)

### 1. 会員情報削除後にシートが閉じない（`MembershipFormView.swift:154-162`）

```swift
private func deleteMembership() async {
    guard case .edit(let membership) = mode else { return }
    isDeleting = true
    let ok = await identityStore.deleteMembership(membership.id)
    isDeleting = false
    guard ok else { return }
    await notifications.rescheduleIfAuthorized()   // ← ここで await している間に自分が消える
    dismiss()
}
```

**何が起きるか**

1. `identityStore.deleteMembership` 成功 → `IdentityStore.memberships` から当該行が消える（`IdentityStore.swift:283-296`）
2. `SheetContentView.swift:34-38` は `identityStore.memberships.first(where:)` で毎回引き直しているので、
   body が再評価されて **`MembershipFormView` が `EmptyStateView("会員情報が見つかりません")` に差し替わる**
3. 再評価が走る猶予を作っているのが次行の `await notifications.rescheduleIfAuthorized()`。
   実体は `MeigichoApp.swift:225-231` の `await notificationPermission.refresh()`（UNUserNotificationCenter への
   実 IPC）＋ `notificationScheduler.reschedule(...)` で、確実に複数回 runloop を明け渡す
4. 再開後の `dismiss()` は**既にビュー階層から外れた `MembershipFormView` が捕まえていた `DismissAction`**
   に対する呼び出しになる。SwiftUI ではこの状態の `DismissAction` は no-op になり得る

**帰結**: シートに「会員情報が見つかりません」が残る。`EmptyStateView` にはツールバーが無く、
`MembershipFormView` が持っていた「キャンセル」ボタンも消えているため、
ユーザーに残る脱出手段はスワイプダウンだけになる。仮に `dismiss()` が効いたとしても、
削除のたびに「会員情報が見つかりません」が一瞬見える（確実に発生する誤表示）。

**根拠となる平仄**: 同じ機能内の他 2 経路は**先に画面を閉じてから**再スケジュールしており、
この 1 本だけ順序が逆になっている。

- `IdentityDetailView.swift:88-96`: `path.removeLast()` → `await notifications.rescheduleIfAuthorized()`
- `ApplicationDetailView.swift:98-105`: `path.removeLast()` → `await notifications.rescheduleIfAuthorized()`

**修正案**: `guard ok else { return }` の直後に `dismiss()` を呼び、通知の再スケジュールはその後に回す。

```swift
guard ok else { return }
dismiss()
await notifications.rescheduleIfAuthorized()
```

`deleteMembership` から戻った直後は同じ MainActor ターン内なので、再レンダリング前に `dismiss()` が走る。

---

## 中 (Should Fix)

### 2. FR-IE-5「入会日は未設定にできる」に到達する UI 経路が無い（`IdentityFormView.swift:60-63, 124-126`）

- `requirements.md` FR-IE-5 は「入会日は**未設定にできる**」と「未設定の名義を触らず保存したら未設定のまま」の
  2 つを求めている。実装は後者だけを満たしている。
- `IdentityEditPlanner.swift:54-56` は `.set(nil)` を作れるし、
  `IdentityEditPlannerTests.swift:82 testExplicitlyClearingJoinedOnSetsNil` がそれを検証しているが、
  **`input.joinedOn` を `nil` にできるフォーム操作が存在しない**（`MembershipFormView.swift:75-84` の
  更新日には `hasRenewalOn` トグルがあるのに、名義の入会日には対応する UI が無い）。
  = 到達不能なコードを守っているテスト（IOS-1 / IOS-3 の変種）。AC-IE-05 は実質未達。
- 併発して `joinedOnBinding`（`:124-126`）は `joinedOn ?? today` を get に返すため、
  未設定の名義で DatePicker に一度でも触れると `today` が入る。「触らなければ大丈夫」という
  細い前提の上に AC-IE-04 が乗っている。

**修正案**: 更新日と同じ「入会日を設定する」トグルを足すか、FR-IE-5 の前半をスコープ外として
`requirements.md` / `plan.md` に明記してテストの意図をコメントで縮小する。

### 3. 追加フォームに他画面のエラーが残って表示される（`IdentityFormView.swift:44-46, 107-119` / `MembershipFormView.swift:59-61, 166-178`）

`populateInitialValues()` が `identityStore.actionError = nil` を実行するのは `.edit` 分岐だけ。
一方 `ErrorBar` は `mode` に関係なく body 先頭に置かれている。

`IdentityStore.actionError` はカラー変更（`IdentityStore.swift:330-333`）・備考インライン編集
（`:345-350`）・共有スイッチなど**別画面の失敗でも立つグローバルな 1 本**なので、
それらが失敗した直後に「名義を追加」「会員情報を追加」を開くと、**追加フォームの先頭に
無関係なエラーバーが出る**。旧 `AddIdentityView` / `AddMembershipView` にはエラーバー自体が
無かったので、TE-4 / TE-5 の「振る舞い不変の抽出」から外れた挙動変化でもある。

**修正案**: `populateInitialValues()` の `.create` 分岐でも `actionError = nil` にする、
または `ErrorBar` を `if mode.isEdit` で囲う。

### 4. 削除確認ダイアログの申込件数がページング済み分しか数えない（`IdentityDetailView.swift:75-83`）

```swift
let repApplicationCount = applicationStore.applications(for: identity.id)
    .filter { $0.repIdentityID == identity.id }.count
```

`applicationStore.applications` は `load()` / `loadMore()` で積み増すページングされた配列なので、
申込が多いユーザーが名義詳細へ直行した場合、**FR-DEL-7 が求める「実データの件数」より少ない数字**が
ダイアログに出る（0 件と表示されうる）。`IdentityStore` から `ApplicationStore` を参照しない方針
（`plan.md` T4）自体は正しく守れているので、問題は件数ソースの側。

**修正案**: 文言を「申込の記録は残ります」と件数無しにするか、
`ApplicationStore` 側に件数を返す API（サーバー集計または全件ロード保証）を用意する。
少なくとも「表示中の申込 N 件」であることを plan の既知の制限として記録する。

---

## 軽微 (Nice to Have)

1. **同語反復的なテスト**: `IdentityStoreDeleteTests.swift:65-76`
   `testDeleteIdentityDoesNotReferenceApplicationStore` は
   `testDeleteIdentitySuccessRemovesIdentityAndItsMemberships` のアサーションの部分集合しか実行しておらず、
   主張したい「`ApplicationStore` を知らなくても削除できる」はコンパイル時性質。ランタイムテストとしては
   回帰を検出しない。コメントで意図を残しつつ削除するか、`XCTAssert` を足すのではなく
   plan 側の設計判断メモに寄せるほうが誠実。

2. **`ApplicationStore` の in-memory 値が DB とずれる**:
   `deleteIdentity` / `deleteMembership` 成功後、`ApplicationStore.applications[*].repMembershipID` は
   削除済み membership を指したまま残る（`load()` まで解消されない）。
   現状 UI では `repMembershipID` を描画していないうえ、`ApplicationEditPlanner.swift:121` が
   `repMembershipID = .unchanged` に固定しているため**書き戻しは起きない**（BE-9 の穴にはなっていない）。
   ただし将来 `repMembershipID` を表示・編集する画面を足すときに踏む地雷なので、
   `IdentityStore.deleteMembership` の doc コメント（`IdentityStore.swift:277-282`）へ
   「`ApplicationStore` 側のローカル配列は更新されない」と明記しておくとよい。

3. **`.unchanged` の明示代入が冗長**: `IdentityEditPlanner.swift:61-62` /
   `MembershipEditPlanner.swift:57-60` は既定値と同じ値を代入している。
   意図（FR-IE-3 / FR-IE-19 を読み手に示す）は理解できるので、そのままでも可。

4. **保存中フラグの持ち方が 2 系統**: `ApplicationDetailView.swift:264` は
   `applicationStore.isSaving`、`IdentityDetailView.swift:118` はローカル `@State isDeleting`。
   `IdentityStore` に `isSaving` が無いので現状の選択は妥当だが、
   将来 `IdentityStore` に足すときに二重管理にしないこと。

5. **本 Issue のスコープ外の差分が同じ作業ツリーに混ざっている**（コミットを分けることを推奨）:
   - `Domain/Models/HomeStatCards.swift` + `HomeStatCardsTests.swift` + `Features/Home/HomeView.swift:204-219`
     + `App/MeigichoApp.swift:196-202`（ホーム 3 指標カードのバグ修正）
   - `meigicho/project.yml` + `Meigicho.xcodeproj/project.pbxproj`
     （`DEVELOPMENT_TEAM` / `MARKETING_VERSION` / Release `API_BASE_URL` / AppIcon 設定）
   - `meigicho/App/Assets.xcassets/`（AppIcon 追加）
   - `docs/plans/identity-grouping/` / `membership-full-number/` / `tour-edit-and-delete/`（別機能の計画）

   なお **IOS-8 は満たされている**: `project.yml` の変更が `project.pbxproj` にも反映済み
   （`DevelopmentTeam = LK3WH7HBCH` / `PBXResourcesBuildPhase` の追加を確認）。

6. **公開リポジトリ前提の確認**: `project.yml:68` に本番 Cloud Run URL、`:83` に Apple Team ID
   （`LK3WH7HBCH`）が平文で入った。いずれも秘密情報ではないが、意図的なコミットかは要確認。

---

## 良かった点

### アーキテクチャ・レイヤリング（全て検証済み）

- `Features` から `DataStore` / `Networking` への import はゼロ（grep で確認）。IOS-5 遵守
- `Domain` に `SwiftData` の import はゼロ
- `IdentityStore` は `ApplicationStore` / `ApplicationRepository` を型として一切参照していない
  （出現箇所は全てコメント）。相互参照禁止を守ったまま FR-DEL-7 の件数合成を View 側へ逃がしている
- `MembershipCard`（DesignSystem）の API を変えず、Features 側で
  `Button` + `.contentShape(Rectangle())` + `.buttonStyle(.plain)` で包んでいる（`IdentityDetailView.swift:190-203`）

### BE-9（書き込み経路 2 本のうち片方だけ検証・後始末）を実際に閉じている

`MembershipDeletionCascade.clearApplicationsReferencing` を**単一の共通処理**として切り出し、

- `SwiftDataIdentityRepository.delete`（名義削除 → 配下 membership 連鎖）
- `SwiftDataMembershipRepository.delete`（membership 単体削除）

の**両方**から呼んでいる。両経路とも `now` を 1 つ作って共有し、`context.save()` は 1 回。
`OutboxQueue.enqueue` は `targetID` で冪等（`OutboxQueue.swift:12-24`）なので二重積みも起きない。
`SwiftDataIdentityRepositoryDeleteTests` / `SwiftDataMembershipRepositoryDeleteCascadeTests` が
「連鎖する」「無関係な行は触らない」「削除済み再削除は `.notFound`」の 3 方向を実測している。

### D-4（無変更スキップ）が Store で強制されている

`IdentityStore.updateIdentity:231-234` / `updateMembership:257-260` の
`guard patch != IdentityPatch()` / `!= MembershipPatch()` で、無変更時にリポジトリを呼ばない。
`IdentityStoreEditTests.testUpdateIdentityNoChangeDoesNotCallRepository` /
`testUpdateMembershipNoChangeDoesNotCallRepository` が Fake の `updateCalls` が空であることを
アサートしており、`updated_at` を空振りで進めない保証が回帰テストになっている。

### D-5 / IOS-13（後付け undo を書かない）

削除 3 本・編集 2 本すべてが「`await` → 成功で反映 / 失敗は据え置き + エラー」。
成功・失敗・repository nil の 3 経路がテストで固定されている
（`IdentityStoreDeleteTests` / `IdentityStoreEditTests` / `ApplicationStoreNetworkTests:465-506`）。
既存の楽観更新 3 経路（`updateIdentityColor` / `updateIdentityNote` / `toggleHistoryVisible`）は
差分に一切含まれていない（`IdentityDetailView` の変更は追加のみで、インライン編集部分は無改変）。

### BE-2 / R-2（未知 `relation` の書き潰し）が構造的に防がれている

`IdentityEditPlanner` が `relation` 未操作時に `.unchanged` を返す → `IdentityRecord.apply(patch:)` が
`relationRaw` を書かない → `IdentityRecord+SyncPayload.swift:10` が
`.string(relationRaw)`（`relation.rawValue` ではない）を送るため、未知 raw が保存されたまま往復する。
`IdentityEditPlannerTests.testUntouchedRelationStaysUnchangedEvenWhenFallenBackToOther` が
`.other` フォールバック済みの値でも `.unchanged` になることを固定している。

### API 契約 3 層（変更ゼロを実測で確認）

- `prisma/schema.prisma` は無変更
- `apps/api/src` の**製品コードは 1 行も変わっていない**（差分は `sync.service.spec.ts` のみ）
- `IdentityRecord+SyncPayload` / `MembershipRecord+SyncPayload` の payload キーは無変更
  （`MembershipRecord+SyncPayload.swift` の追加は `fetchActive(identityID:)` ヘルパーのみで、
  `syncPayload()` は無改変）。`op` は削除でも `upsert` のまま

### BE テストが BE-10 安全な形で書かれている

`sync.service.spec.ts` の `tx` は `prisma` とデリゲートを共有しない独立オブジェクト（`:39-71`）。
AC-13 は `IdentitiesService` の**実インスタンス**を組んで `ensureWithinLimit` の early return
（`identities.service.ts:141-144`）を統合で通し、`entitlementsStub.identityLimit` が
呼ばれないことをアサートしている（モックで自明化していない）。

### IOS-1（実装済み未配線）の解消

以前 呼び出し元ゼロだった `IdentityRepository.delete` / `MembershipRepository.delete` /
`MembershipRepository.update` が、いずれも UI まで縦串で繋がった:

| protocol メソッド | Store | UI 導線 |
|---|---|---|
| `IdentityRepository.delete` | `IdentityStore.deleteIdentity` | `IdentityDetailView` 本文最下部 |
| `IdentityRepository.update` | `IdentityStore.updateIdentity` | `IdentityDetailView` ツールバー「編集」→ `AppSheet.editIdentity` |
| `MembershipRepository.update` | `IdentityStore.updateMembership` | 会員情報カードタップ → `AppSheet.editMembership` |
| `MembershipRepository.delete` | `IdentityStore.deleteMembership` | `MembershipFormView` 最下部（※重大 1 の順序問題あり） |
| `ApplicationRepository.delete` | `ApplicationStore.deleteApplication` | `ApplicationDetailView` 本文最下部 |

### 広告禁止画面テストの取り扱い（D-7 の罠を両方回避）

- 旧 `AddIdentityView.swift` / `AddMembershipView.swift` は**薄いラッパとして残っている**
  （`try String(contentsOf:)` が throw しない）
- 新 `Forms/IdentityFormView.swift` / `Forms/MembershipFormView.swift` を
  `AdSlotForbiddenScreensTests.swift:14-17` と `AdGatekeeperTests.swift:140-143` の**両方**に追加済み
- 両パッケージのテストが緑（実行確認済み）

### docs 追従

`docs/09-roadmap.md` に 0-5b / 0-6b、`docs/05-ios-client.md` に S7/S8 拡張（導線表・削除の連鎖規則）、
`docs/01-product-overview.md` に R1-7 と「復元 UI 未実装」注記。
**「復元可能期間30日」との既知の乖離を 3 ファイルに明示的に記録している**のが特に良い
（仕様と実装の嘘を残さない）。

---

## 手動確認が必要な残項目

機械ゲートでは検出できないため、`identity-edit-and-delete/plan.md` §6 と
`delete-ui/plan.md` §5 の手順を実機/シミュレータで実施すること。特に:

1. **重大 1 の再現確認**: 会員情報編集シート最下部「この会員情報を削除」→ シートが閉じるか、
   「会員情報が見つかりません」で止まらないか（修正前に一度再現させてから直すことを推奨）
2. AC-IE-22（回帰）: 名義カラーピッカー・備考インライン編集・共有スイッチ・
   名義追加後の会員情報シート連続遷移
3. AC-IE-16: 会員情報**編集**で通知許可シートが出ないこと
4. AC-IE-11: `rank` / `auto_renew` / `note` を持つ会員情報を編集保存しても値が消えないこと（サーバー側で確認）
5. 中 3 の再現: 名義カラー変更を失敗させた直後に「名義を追加」を開き、エラーバーが残らないか

---

## 再レビュー結果（2026-08-20 フォローアップ）

- 対象: 前回指摘（重大1・中3件）への修正差分。`MembershipFormView.swift` / `IdentityFormView.swift` / `IdentityDetailView.swift`
- レビュアー: code-reviewer（実装者とは別セッション）

### 検証ゲート実行結果（全て緑）

| コマンド | 結果 |
|---|---|
| `swift test --package-path meigicho/Packages/Domain` | 263 tests, 0 failures |
| `swift test --package-path meigicho/Packages/DataStore` | 50 tests, 0 failures |
| `swift test --package-path meigicho/Packages/DesignSystem` | 1 test, 0 failures |
| `xcodebuild ... build` | BUILD SUCCEEDED（warning 0 件） |

### 前回指摘への対応確認

1. **重大1（dismiss 順序）: 解消を確認**（`MembershipFormView.swift:157-165`）
   `guard ok else { return }` の直後に `dismiss()` を呼び、`await notifications.rescheduleIfAuthorized()` はその後に移動済み。
   `IdentityDetailView.deleteIdentity`（`:96-105`）・`ApplicationDetailView` と同じ「先に画面遷移、後で通知再スケジュール」の順序に揃った。
   doc コメント（`:151-156`）に根拠（再評価で `EmptyStateView` に差し替わる問題）も明記されている。

2. **中2（入会日クリア UI 欠如）: 解消を確認**（`IdentityFormView.swift:61-76, 125-140`）
   `.edit` モードのみ「入会日を設定する」トグルを追加（`mode.isEdit` で分岐、`.create` は従来どおり常時 DatePicker）。
   `populateInitialValues()` で `hasJoinedOn = identity.joinedOn != nil` として現在値を復元。
   `saveEdit` は `joinedOn: hasJoinedOn ? joinedOn : nil` を `IdentityEditFormInput` に渡し、`IdentityEditPlanner.makePatch`
   の `input.joinedOn != current.joinedOn` 比較と整合（未操作なら `.unchanged`、明示クリアなら `.set(nil)`）。
   `.create` フローの見た目・既定値は変更なし（NFR-1 順守）。

3. **中3（actionError の持ち越し）: 解消を確認**（`IdentityFormView.swift:126` / `MembershipFormView.swift:174`）
   `populateInitialValues()` の `switch` の**外**、モード共通で `identityStore.actionError = nil` を実行するよう修正済み。
   両ファイルの doc コメントに「`actionError` はグローバルな1本なので、モードによらずフォームを開いた時点でクリアする」と理由も明記。

4. **中4（削除確認ダイアログの申込件数）: 妥当な方針で解消を確認**（`IdentityDetailView.swift:74-91`）
   `applicationStore.applicationsState == .loaded && !applicationStore.truncated` をガードとして追加。
   条件を満たさない場合は「会員情報 N 件も一緒に削除されます。申込の記録は残ります。」と**件数を出さない文言**にフォールバックし、
   条件を満たす場合のみ実測件数を表示する。サーバー集計 API を新設せずに「不正確になりうる場合は数字を見せない」方針は、
   FR-DEL-7 の要求（実データ件数の周知）と実装コストのバランスとして妥当。doc コメント（`:78-81`）に判断根拠も明記されている。

### 新たな重大の有無

なし。4件とも実装・テスト・ビルドで確認済み。

### 結論

**マージ可**。前回指摘の重大1件・中3件はすべて解消を確認した。新規の重大は検出されなかった。
