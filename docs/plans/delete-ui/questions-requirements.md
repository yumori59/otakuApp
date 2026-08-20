# delete-ui — 確定が必要な論点

ユーザー原文（機能監査への回答）: 「確かに削除機能は実装して欲しいです」。対象は**名義（Identity）と申込（Application）の両方**。

各 Q には「未回答でも計画を止めない」ためのデフォルト仮定を置いてある。
**回答が来たら `[Answer]:` 行に書き戻し、differ があれば `requirements.md` / `plan.md` を先に直す。**

---

## 確定ステータス（2026-08-20・planner 再点検）

`docs/plans/identity-edit-and-delete/` の Inception で Q1〜Q9 を全件再点検し、**デフォルト仮定をそのまま確定回答として採択した**。

- `[Answer]:` 行は **planner による確定**であり、ユーザーが個別に選択肢を選んだ記録ではない。
  ユーザーの明示指示は「削除機能を実装して欲しい」「名義の編集・削除ができるように」までで、選択肢レベルの指示は無い。
- 再点検で 1 件だけ**追記が必要な差分**が出た（Q1）。名義詳細に「編集」ツールバーが増えるため、
  削除ボタンの位置が編集と衝突しないことを明記した。`requirements.md` / `plan.md` の記述変更は不要。
- 覆したい判断があれば、この節と該当 `[Answer]:` を書き換えてから `requirements.md` / `plan.md` を直す。

---

## 先に確定している事実（調査済み・質問ではない）

| # | 事実 | 根拠 |
|---|---|---|
| F1 | BE の削除は**ソフトデリートのみ**。`DELETE /v1/identities/:id` は identity 1 行に `deletedAt` を打つだけで、**memberships にも applications にも連鎖しない** | `apps/api/src/identities/identities.service.ts:116-129` |
| F2 | `DELETE /v1/applications/:id` は同一 TX で `application_companions` も連鎖ソフトデリートする | `apps/api/src/applications/applications.service.ts:108-125` |
| F3 | iOS の実際の書き込み経路は REST DELETE ではなく **ローカル SwiftData → outbox → `POST /v1/sync/push`**。`deleted_at` は全 6 コレクションの payload に既に含まれる | `SwiftDataApplicationRepository.delete:194-209` / `IdentityRecord+SyncPayload.swift:22-24` |
| F4 | `IdentityRepository.delete` / `ApplicationRepository.delete` は **protocol・SwiftData 実装・InMemory 実装ともに既に存在する**（呼び出し元がゼロ = 実装済み未配線） | `Repositories.swift:51,79` / `SwiftDataIdentityRepository.swift:52` / `SwiftDataApplicationRepository.swift:194` / `InMemoryRepositories.swift:36,194` |
| F5 | 一方、**`IdentityStore` / `ApplicationStore` に削除メソッドは 1 つも無い**。UI から Repository までの縦串が Store の位置で切れている | `Stores/IdentityStore.swift`・`Stores/ApplicationStore.swift`（`delete` 該当メソッド無し） |
| F6 | BE は「削除済み名義に紐づく会員情報」を**読むたびに除外**している（`identity: { deletedAt: null }`）。つまり「連鎖しない」ことは既知の設計で、読み側でフィルタする方針 | `apps/api/src/home/home.service.ts:53-55` |
| F7 | ところが **iOS には同等のフィルタが無い**。`IdentityStore.expiringMembershipCount:91-97` と `NotificationScheduler.reschedule:41-49` は `memberships` を無条件に走査する | 同上 |
| F8 | 共有リンクは名義 id も申込 id も参照しない（スコープは `identity_summary`（全名義集計）か `tour`（tour_id））。**削除で共有リンクが壊れることはない** | `shares/shares.service.ts:172,190` / `shares/board/identity-summary.service.ts:32-33` |
| F9 | 共有ボードの名義集計は未削除名義のみを対象にする（`identities.list(ownerId, false)`）ので、削除した名義は共有先から**自動的に消える** | `identity-summary.service.ts:33` |
| F10 | ツアー表（`tour-matrix.service.ts:71-88`）は削除済み event / application / companion を除外するが、**`repIdentity` は `deletedAt` で絞っていない**。削除済み名義を代表とする申込が残っていれば、その名義名は共有先にも出続ける | `tour-matrix.service.ts:74-88,104-105` |
| F11 | 一覧画面は `List` ではなく `ScrollView` + `CardList` + `ForEach` で組まれており、`.swipeActions` は使えない | `IdentityListView.swift:118-123` / `ApplicationListView.swift:176,212` |
| F12 | `docs/01-product-overview.md:250` は「削除は全てソフトデリート**＋復元可能期間30日**」と書いているが、**復元 UI も復元 API も存在しない** | 同行 / `apps/api/src` に restore エンドポイント無し |

---

## Q1. 削除の導線をどこに置くか

| 選択肢 | 内容 | 影響 |
|---|---|---|
| A | **詳細画面のみ**（名義詳細・申込詳細の最下部に destructive ボタン） | 実装最小。誤操作しにくい。既存の「編集」導線（`ApplicationDetailView.swift:56-69`）と同じ場所で完結 |
| B | A + 一覧のスワイプ削除 | 一覧は `List` ではないため（F11）`ScrollView`/`CardList` を `List` へ書き換える大改修が必要。カード見た目・広告枠（`PlacementAdSlot`）・並び替えの回帰リスクが大きい |
| C | 一覧のみ | 詳細から削除できず動線として不自然 |

- **デフォルト仮定: A**
- 理由: B は「削除 UI の追加」ではなく「一覧画面の作り替え」になり、費用対効果が合わない。まず A を出し、要望が出たら別計画で B を検討する。

`[Answer]: A（詳細画面のみ）で確定`（planner 確定・2026-08-20）

- **追記（再点検の差分）**: `docs/plans/identity-edit-and-delete/` で `IdentityDetailView` の
  `topBarTrailing` に「編集」を置く（`ApplicationDetailView.swift:56-69` と同形）。
  したがって**削除は 2 画面とも本文最下部**に置く（`plan.md` D-4 のとおり）。
  ツールバーへ削除を追加してはいけない（編集と隣り合って誤タップの導線になる）。
- 会員情報（Membership）単体の削除だけは詳細画面が存在しないため、
  会員情報の**編集シート最下部**に置く（`identity-edit-and-delete/plan.md` D-6）。本 Q の A と矛盾しない。

---

## Q2. 確認ダイアログの要否と文言

ソフトデリートだがアプリ内に復元手段が無い（F12）ため、ユーザー体験としては**不可逆**。

- **デフォルト仮定: 必須**。`confirmationDialog` で destructive ボタン + キャンセル。
  - 申込: 「この申込を削除しますか？ 同行者の記録も一緒に削除されます。」
  - 名義: 「『〇〇』を削除しますか？ 会員情報 N 件も一緒に削除されます。申込 M 件の記録は残ります。」（N / M は実データから算出）
- 却下: テキスト入力による確認（アカウント削除相当の重さ）。名義 1 件の削除にしては過剰。

`[Answer]: 必須で確定`（planner 確定・2026-08-20）

- 再点検: 復元手段が無い（F12）ことは今も変わらない。ダイアログ必須の判断は維持。

---

## Q3. 名義を削除したとき、その名義の FC 会員情報（Membership）はどうするか

BE は連鎖しない（F1）。ただし iOS 側は削除済み名義の会員情報を除外していない（F7）ため、**放置すると「名義」という無名の FC 更新通知が鳴り続ける**（`NotificationScheduler.swift:45` の `identityNames[...] ?? "名義"` に落ちる）。

| 選択肢 | 内容 | 影響 |
|---|---|---|
| A | **クライアント側で連鎖ソフトデリート**（identity + その memberships を 1 セーブでまとめて tombstone 化し push） | 通知・ホームの「更新が近い」件数・ローカル一覧すべてが一度に整合する。サーバー上でも memberships が削除済みになるので、他端末でも同じ結果になる |
| B | 会員情報は残し、iOS の読み側全てに「削除済み名義を除く」フィルタを足す（BE と同じ方針 = F6） | 消し忘れた読み経路が静かにバグる。サーバーには生きた会員情報が残り続け、`GET /v1/memberships` は返し続ける |
| C | 何もしない | F7 の通知バグがそのまま残る |

- **デフォルト仮定: A**
- 併せて: BE の `memberships.remove` は削除される membership を参照する申込の `rep_membership_id` を同一 TX で `null` にする（`memberships.service.ts:156-165`）。**iOS の `SwiftDataMembershipRepository.delete:64-73` にはこの処理が無い**（既存の乖離 / BE-9 型）。A を採るなら連鎖処理内で同じクリアを行い、乖離を閉じる。
- 帰結（受け入れる）: 将来「30日以内の復元」（F12）を作るとき、名義を戻しても会員情報は別途戻す実装が要る。

`[Answer]: A（クライアント側で連鎖ソフトデリート）で確定`（planner 確定・2026-08-20）

- 再点検で A を強める事実: `IdentityStore.memberships` は名義 id で絞られておらず（`IdentityStore.swift:78-80,91-97`）、
  B を採ると「削除済み名義を除く」フィルタを `expiringMembershipCount` / `NotificationScheduler` /
  `IdentityDetailView.membershipsSection` / 将来の会員情報編集導線すべてに入れ続ける必要がある。読み経路は今後も増える。
- `plan.md` T1 で作る「`repMembershipID` クリアの共通処理」は、
  `identity-edit-and-delete` の会員情報単体削除（TE-7）からも呼ばれる。**T1 を先に完了させること**。

---

## Q4. 名義を削除したとき、その名義を代表者とする申込はどうするか

| 選択肢 | 内容 |
|---|---|
| A | **申込は残す**（削除しない）。`docs/05-ios-client.md:920` のテスト方針「名義を削除しても申込の記録は残る」と一致 |
| B | 申込も連鎖削除する |
| C | 削除前に「この名義には申込が N 件あります」と警告し、A/B を選ばせる |

- **デフォルト仮定: A**
- 理由: 当落の記録はアプリの価値の中核（`docs/09-roadmap.md:535`）。名義の整理で過去の当落履歴が消えるのは損失が大きい。削除ダイアログには「申込 M 件の記録は残ります」と明記する（Q2）。

`[Answer]: A（申込は残す）で確定`（planner 確定・2026-08-20）

- 再点検: `docs/05-ios-client.md:920` の記述と一致しており、覆すと docs 側の変更が要る。維持。
- 併せて確定: **名義編集で表示名を変えた場合、過去の申込の代表者表示も新しい名前になる**
  （`Application.repIdentityID` を辿るため）。改名で履歴の見え方が変わるのは仕様として受け入れる
  （`identity-edit-and-delete/requirements.md` FR-IE-9）。

---

## Q5. 削除済み名義を代表者とする申込の表示

現状 `ApplicationDetailView.swift:134` は `rep?.displayName ?? "不明"` で **「不明 ›」というリンクになり、タップすると「名義が見つかりません」画面に飛ぶ**（`IdentityDetailView.swift:36`）。

| 選択肢 | 内容 |
|---|---|
| A | 表示を「削除された名義」にし、**リンクを無効化**（タップ不可・アイコンとグレー表示） |
| B | 削除済み名義の表示名をローカル DB から引いて「〇〇（削除済み）」と出す。`IdentityStore` に削除済みも保持する経路が必要（`IdentityRepository.list()` は `deletedAt == nil` で絞っている = `SwiftDataIdentityRepository.swift:20`） |
| C | 現状維持（「不明」のままリンクも生きる） |

- **デフォルト仮定: A**
- 理由: B は Store / Repository の読み契約を広げる必要があり、削除 UI の付随作業としては重い。C は行き止まりリンクで明確な不具合。
- 同じ扱いを `ApplicationListView` / ツアー表の代表者名にも適用するかは A の範囲内で確認する（現状これらは `identityStore.identity(for:)` の nil フォールバックに依存）。

`[Answer]: A（「削除された名義」+ リンク無効化）で確定`（planner 確定・2026-08-20）

- 再点検: B は `IdentityRepository.list()` の契約（`SwiftDataIdentityRepository.swift:20` の
  `deletedAt == nil` 絞り込み）を広げる必要があり、同じ `IdentityStore.identities` を
  名義編集フォームの現在値・名義一覧・上限判定が共有しているため、影響が削除 UI の外へ出る。A を維持。

---

## Q6. 削除した名義が「同行者」になっている申込の表示

`ApplicationCompanion` は `identity_id`（nullable）と `display_name` の両方を持つ。名義を削除しても `display_name` は残る。

- **デフォルト仮定: 表示名はそのまま残し、名義詳細へのリンクだけ無効化する**（Q5-A と同じ判定を `ApplicationDetailView.swift:143-155` に適用）
- 補足（BE 側・変更しない）: ツアー表は `companion.identity?.displayName ?? companion.displayName` で**削除済み名義の現在名を優先**する（`tour-matrix.service.ts:107-110`）。共有先にも名前は出続ける。これは仕様どおり（F10）とし、本計画では変更しない。

`[Answer]: 表示名は残し、リンクだけ無効化で確定`（planner 確定・2026-08-20）

- 再点検で見えた副作用（受け入れる）: 名義編集で表示名を変えると、
  ツアー表・共有ボードの**同行者名も新しい名前に変わる**（`tour-matrix.service.ts:107-110` が
  `companion.identity.displayName` を優先するため）。`ApplicationCompanion.display_name` は追随しない。
  削除済み名義の名前が出続ける点（F10）と同じ既存挙動で、本計画でも `identity-edit-and-delete` でも変更しない。

---

## Q7. 「復元可能期間30日」（`docs/01:250`）に対応する復元 UI を今回作るか

- **デフォルト仮定: 対象外**。今回は削除のみ。ただし `docs/01-product-overview.md:250` と実装の乖離を `requirements.md` のリスクとして明記し、`docs/09-roadmap.md` に未実装項目として残す。
- 却下: 今回まとめて実装。復元は「一覧に削除済みを出す」「サーバーの `include_deleted` 経路を使う」「同期の LWW と復活の整合」まで波及し、削除 UI の 2〜3 倍の規模になる。

`[Answer]: 対象外で確定`（planner 確定・2026-08-20）

- ただし `docs/01-product-overview.md:250` との乖離を放置しない条件付き。`plan.md` T8 の docs 追従は必須タスクとして残す。

---

## Q8. 削除後の画面遷移とフィードバック

- **デフォルト仮定**: 削除に成功したら詳細画面を閉じて一覧（呼び出し元）へ戻る（`path.removeLast()`）。トーストは出さない（一覧から消えること自体がフィードバック）。失敗したら画面に留まり `ErrorBar` に理由を出す（`ApplicationDetailView.swift:29-31` / `IdentityDetailView.swift:25-27` の既存の枠を再利用）。
- 名義詳細から申込詳細へ入って申込を削除した場合も同じ（1 つ戻る）。

`[Answer]: 1 つ戻る / トーストなし / 失敗時は留まって ErrorBar で確定`（planner 確定・2026-08-20）

- 再点検: 編集（`identity-edit-and-delete`）の保存後も「シートを閉じるだけ・トーストなし」で揃える（FR-IE-12）。
  削除と編集でフィードバックの流儀を分けない。

---

## Q9. ゲスト（未ログイン）時の扱い

未ログインでは一覧が空になり詳細画面へ到達できない（`IdentityListView.swift:86-90` / `ApplicationListView.swift:89-90`）。

- **デフォルト仮定: 削除にサインインゲート（`SheetPresenter.present(_:requiringSignIn:reason:)`）を掛けない**。到達不能なため。
- 却下: 「編集」と同じくゲートを掛ける。理由の文言（`SignInPrompt`）を増やすだけで、実際には発火しない死にコードになる。

`[Answer]: ゲートを掛けないで確定`（planner 確定・2026-08-20）

- 再点検: `IdentityListView.swift:86-90` の `auth.isGuest` 分岐は今も生きており、
  ゲストは詳細画面へ到達できない。名義編集（`identity-edit-and-delete`）も同じ理由でゲートを掛けない（FR-IE-14）。
