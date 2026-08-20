# identity-edit-and-delete — 確定が必要な論点

ユーザー原文: 「アカウント（＝名義 Identity）の編集・削除ができるように」。

**削除**は `docs/plans/delete-ui/` に計画済み（未実装）。本計画は削除を**そのまま引き継ぎ**、
新規に **名義の編集**と、その周辺で穴になっている **FC 会員情報の編集・単体削除**を定義する。

各 Q にデフォルト仮定を置く。**回答が来たら `[Answer]:` に書き戻し、differ があれば
`requirements.md` / `plan.md` を先に直す。** `[Answer]:` が「planner 確定」と書かれているものは、
ユーザーが選択肢を選んだ記録ではなく、根拠付きで採択した既定値である。

---

## 先に確定している事実（調査済み・質問ではない）

| # | 事実 | 根拠 |
|---|---|---|
| G1 | `IdentityPatch` は **displayName / relation / colorHex / joinedOn / note / historyVisible / sortOrder の全 7 項目を既に持つ** | `Domain/Sources/Domain/Models/Patches.swift:4-14` |
| G2 | `IdentityRepository.update(id:_:)` は protocol・SwiftData・InMemory の 3 系統すべて実装済みで、**呼び出し元もある**（色・備考・共有スイッチ） | `Repositories.swift:50` / `SwiftDataIdentityRepository.swift:40-50` / `InMemoryRepositories.swift:22-34` / `IdentityStore.swift:146-185` |
| G3 | ところが `IdentityStore` に**表示名・関係性・入会日を変える口が無い**。あるのは `updateIdentityColor` / `updateIdentityNote` / `toggleHistoryVisible` の 3 本だけ。**一度付けた名義名は二度と直せない** | `IdentityStore.swift:146-185`（`displayName` / `relation` / `joinedOn` を書く経路が存在しない） |
| G4 | `MembershipPatch` と `MembershipRepository.update` も 3 系統すべて実装済み。しかし **`IdentityStore` に会員情報の更新メソッドが無く、呼び出し元がゼロ**（実装済み未配線 = IOS-1） | `Patches.swift:16-27` / `SwiftDataMembershipRepository.swift:45-62` / `IdentityStore.swift`（`updateMembership` 該当なし） |
| G5 | 会員情報を直す手段が**アプリ内に一切無い**。更新日を打ち間違えると FC 更新通知が誤った日に鳴り続け、直すには名義ごと消すしかない | `AddMembershipView.swift`（追加のみ）/ `IdentityDetailView.swift:120-136`（カードは表示専用） |
| G6 | BE は `PATCH /v1/identities/:id`（`update-identity.dto.ts`）と `PATCH /v1/memberships/:id`（`update-membership.dto.ts`）を実装済み。**BE の追加実装は不要** | 同 DTO / `identities.controller.ts` / `memberships.controller.ts` |
| G7 | ただし iOS の実際の書き込み経路は REST PATCH ではなく **ローカル SwiftData → outbox → `POST /v1/sync/push`**。本番構成が `SwiftData*Repository` を注入するため | `docs/plans/application-edit/plan.md` D-1 / `delete-ui/requirements.md` C-2 |
| G8 | `POST /v1/sync/push` の payload は **`@IsObject()` だけで、フィールド単位の検証が無い**。DTO の `@MinLength(1)` / `@IsIn(IDENTITY_RELATIONS)` は同期経路では効かない。Prisma も `displayName String` / `relation String` で制約が無い | `sync/dto/sync.dto.ts:29-31` / `sync/sync-payload.mapper.ts:29-38` / `prisma/schema.prisma:106-107` |
| G9 | 名義上限チェックは**既存行の更新では発火しない**（`ensureWithinLimit` が `existing` を見つけて早期 return）。上限超過状態でも編集は通る | `identities.service.ts:141-144` / `sync.service.ts:140-149` |
| G10 | `IdentityRecord.relation` の getter は `Relation(rawValue:) ?? .other` で**未知値を黙って `.other` に落とす**。この値のまま保存すると、サーバー上の未知 raw 値が `"other"` に書き潰される（BE-2 の iOS 版） | `IdentityRecord.swift:57-59` |
| G11 | `Identity.joinedOn` は `Date?` だが、`AddIdentityView` は「未設定」を選べず必ず今日を入れる。pull では `null` が入りうる | `Models.swift:12` / `AddIdentityView.swift:15,72` |
| G12 | 追加フォームを create/edit 兼用の `*FormView(mode:)` に統合する前例がある（申込編集）。`ApplicationFormMode` は `.create` / `.edit(entry)` の 2 ケース | `Features/Forms/ApplicationFormView.swift:11-19` / `AppRoute.swift:23,36` / `SheetContentView.swift:19-24` |
| G13 | 編集の差分計算を Domain の純粋関数へ切り出して XCTest で固定する前例がある（`ApplicationEditPlanner`） | `application-edit/plan.md` D-2 / `ApplicationStore.swift:395-400` |
| G14 | 「削除された名義」表示やスワイプ削除など、削除まわりの論点は `delete-ui/questions-requirements.md` Q1〜Q9 で 2026-08-20 に全件確定済み | 同ファイル「確定ステータス」節 |

---

## QE1. 名義編集フォームの項目

| 選択肢 | 内容 |
|---|---|
| A | **追加フォームと同一 5 項目**（氏名・関係性・入会日・名義カラー・メモ）。共有スイッチ（`historyVisible`）は詳細画面のスイッチのまま。詳細画面のカラーピッカーと備考インライン編集も**残す** |
| B | 共有スイッチも含む 6 項目にし、詳細画面のカラーピッカー・備考インライン編集を撤去して編集経路を 1 本化 |
| C | 表示名だけ直せるようにする（最小） |

- **デフォルト仮定: A**（planner 確定）
- 理由:
  - 申込編集の前例が「追加フォームと同一 12 項目」（`docs/09-roadmap.md:80`）。同じ流儀に揃える
  - B の撤去対象は `docs/09-roadmap.md:73` が 0-5 の要件として明記している出荷済み挙動（「備考のインライン編集」「カラーピッカー」）。削るなら docs の変更が要る
  - 書き込み経路が 2 本になる懸念（BE-9）は、`Patchable` が「触っていないフィールドはキーごと送らない」ので**古いフォームが他フィールドを書き潰す事故は起きない**（`Patchable.swift:20-25` / `IdentityRecord+Mapping.swift:34-43`）。ただし同期 push は**スカラー全件**を送るため、端末をまたぐと LWW でレコード単位に上書きされる（既存仕様・R-3）
  - C は「関係性・入会日を間違えたら直せない」状態が残る

`[Answer]: A で確定`（planner 確定・2026-08-20）

---

## QE2. FC 会員情報（Membership）の編集・削除をスコープに含めるか

`delete-ui/requirements.md` §4 は「会員情報単体の削除 UI」を明示的にスコープ外にしている。編集は**どの計画にも無い**。

| 選択肢 | 内容 |
|---|---|
| A | **編集も単体削除も含める**。会員情報カードをタップ → 編集シート（最下部に削除） |
| B | 編集だけ含め、単体削除は引き続き対象外（消すには名義ごと削除するしかない） |
| C | どちらも対象外にし、別計画へ回す |

- **デフォルト仮定: A**（planner 確定）
- 理由:
  - G5 のとおり、**更新日の打ち間違いを直す手段がアプリ内に存在しない**。更新日は FC 更新通知（`docs/01`）の入力そのもので、誤りが通知の誤爆として毎回顕在化する。「編集できない」ではなく機能欠損に近い
  - `MembershipRepository.update` は 3 系統とも実装済みで**呼び出し元ゼロ**（G4）。IOS-1 の「実装済み未配線」を放置せず閉じる
  - B は「FC を退会した」を表現できない。名義ごと消すと当落履歴の見え方まで変わる（`delete-ui` Q4-A の趣旨に反する）
  - 単体削除の増分コストが小さい。`repMembershipID` クリアの共通処理は `delete-ui` T1 が作る（同 Q3 の `[Answer]` 追記）ので、本計画では**その共通処理を呼ぶだけ**
- 帰結: 会員情報の単体削除（TE-7）は **`delete-ui` T1 完了後にしか着手できない**。TE-7 を落としても他タスクは独立して完成する

`[Answer]: A で確定`（planner 確定・2026-08-20）

---

## QE3. 会員情報フォームに `rank` / `auto_renew` / `note` を追加するか

モデル・API・`MembershipPatch` には 3 項目とも存在するが、`AddMembershipView` は出していない（FC名・下4桁・更新日・年会費の 4 項目）。

- **デフォルト仮定: 追加しない**（planner 確定）。編集フォームは**追加フォームと同一 4 項目**にする（QE1 と同じ流儀）
- 理由: 3 項目を出すかどうかは「編集を作る」とは独立した製品判断で、追加フォーム側も同時に変えないと create と edit で項目が食い違う。本計画で混ぜると「編集を入れたら追加フォームも変わった」になり、回帰の切り分けができなくなる
- 帰結（受け入れる）: 同期 pull で `rank` / `note` が入っている行を編集して保存しても、**その 2 項目は `.unchanged` なので消えない**（`Patchable`）。編集で値が飛ぶ事故は起きない。これは AC で固定する（AC-IE-11）

`[Answer]: 追加しないで確定`（planner 確定・2026-08-20）

---

## QE4. 編集の導線をどこに置くか

- **デフォルト仮定**（planner 確定）:
  - **名義**: `IdentityDetailView` の `topBarTrailing` に「編集」→ `AppSheet.editIdentity(id:)`。`ApplicationDetailView.swift:56-69` と同形
  - **会員情報**: `IdentityDetailView` の会員情報カードをタップ → `AppSheet.editMembership(id:)`。`MembershipCard` は DesignSystem の表示専用コンポーネントなので**改造せず**、Features 側で `Button` + `.contentShape(Rectangle())` で包む（IOS-5: DesignSystem に画面の関心を持ち込まない）
  - **削除の位置は変えない**: 名義削除は詳細本文最下部のまま（`delete-ui` D-4）。ツールバーが「編集」で埋まるため、削除をツールバーに寄せない
  - 会員情報の単体削除だけは詳細画面が無いので、**編集シート最下部**の destructive ボタンに置く
- 却下: 一覧のスワイプ編集。一覧は `List` ではない（`IdentityListView.swift:118-123` の `CardList` + `ForEach`）ため画面構造の作り替えになる（`delete-ui` Q1-B と同じ理由）

`[Answer]: 上記で確定`（planner 確定・2026-08-20）

---

## QE5. 「変更なしで保存」を押したときの挙動

- **デフォルト仮定: リポジトリを呼ばずにシートを閉じる**（planner 確定）
- 理由: `IdentityRecord.apply(patch:)` は `.unchanged` でも無条件に `markDirty` して `updatedAt` を進め、outbox にも積む（`IdentityRecord+Mapping.swift:42`）。何も変えていない保存で `updated_at` が進むと、**別端末の未送信編集が LWW で負ける**。既存の `IdentityStore.updateIdentityColor:149` も `guard previous != colorHex` で同じ予防をしている
- 判定は Domain の純粋関数側（差分が全件 `.unchanged` か）で行い、XCTest で固定する

`[Answer]: 呼ばずに閉じるで確定`（planner 確定・2026-08-20）

---

## QE6. 保存の反映方式（楽観更新するか）

- **デフォルト仮定: 楽観更新しない**（planner 確定）。保存中は `isSaving`、成功したらリポジトリの戻り値で反映してシートを閉じ、失敗したらシートを閉じずエラーを出す
- 理由: `application-edit/plan.md` D-5 と `delete-ui/plan.md` D-3 が同じ結論。複数フィールドにまたがる変更の「後付け undo」は IOS-13 で焼かれたパターン。書き込み先はローカル SwiftData なので待ち時間は無視できる
- **既存の 3 経路（カラーピッカー・備考・共有スイッチ）は楽観更新のまま変えない**。1 フィールドの巻き戻しは成立しており、触ると回帰リスクだけが増える

`[Answer]: 楽観更新しないで確定`（planner 確定・2026-08-20）

---

## QE7. ゲスト（未ログイン）時の扱い

- **デフォルト仮定: 編集にサインインゲートを掛けない**（planner 確定）。`IdentityListView.swift:86-90` の分岐でゲストは詳細画面へ到達できず、掛けても発火しない死にコードになる（`delete-ui` Q9 と同じ判断）

`[Answer]: ゲートを掛けないで確定`（planner 確定・2026-08-20）

---

## QE8. 未知の `relation` を持つ行を編集したときの扱い（G10）

サーバーに `relation: "partner"` のような未知値が入っている行を編集フォームで開くと、Picker は `.other` を選んだ状態になり、保存すると raw 値が `"other"` に書き潰される。

| 選択肢 | 内容 |
|---|---|
| A | **`relation` に触っていなければ `.unchanged` にして送らない**（フォールバック値を書き戻さない）。差分計算を「フォーム上の選択値」ではなく「ユーザーが Picker を操作したか」に基づかせる |
| B | 現状どおり `.other` を書き戻す |
| C | 未知値の行は編集不可にする |

- **デフォルト仮定: A**（planner 確定）
- 理由: BE-2「クエリ/ボディ enum の黙殺フォールバック」の iOS 版そのもの。A なら追加コストは差分計算の純粋関数に「初期値と一致するなら `.unchanged`」を入れるだけで、QE5 の実装と同じ仕組みで済む
- 現実の発生確率は低い（今の書き手はこのアプリだけ）が、`Relation.decoded` が `didFallback` をわざわざ返している設計（`AppEnums.swift:31-37`）と整合させる
- C は過剰。B は静かなデータ破壊

`[Answer]: A で確定`（planner 確定・2026-08-20）

---

## QE9. 同期 push にフィールド検証が無い件（G8）をどこまで扱うか

編集フォームから空の表示名や 61 文字の表示名を送ると、`PATCH` なら 400 になるのに `sync/push` は素通りして Prisma に入る。

- **デフォルト仮定: 本計画では iOS 側のガードのみ**（planner 確定）。BE の製品コードは変更しない
  - フォームの保存ボタンを空名で disable（`AddIdentityView.swift:68` の踏襲）
  - 差分計算の純粋関数が trim 後に空なら `.unchanged` にする（XCTest で固定）
- **本計画では扱わないが記録する**: `sync/push` に per-collection の payload 検証が無いのは
  **本機能が作った穴ではなく、既に全 6 コレクションにある穴**（BE-9 型）。
  `requirements.md` §7 R-1 に残し、`docs/09-roadmap.md` の技術負債として別計画へ切り出す
- 却下: 本計画で `sync/push` に検証を足す。6 コレクション × 全フィールドの契約確定作業になり、
  名義編集の付随作業の範囲を大きく超える。かつ既存クライアントが送っている値を拒否し始めるリスクがある

`[Answer]: iOS 側ガードのみで確定。BE は別計画`（planner 確定・2026-08-20）
