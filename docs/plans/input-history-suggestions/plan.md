# input-history-suggestions — Workflow Plan

`requirements.md` の受入基準を実装タスクへ分解する。着手前に `questions-requirements.md` の
Q1〜Q8（すべて**仮回答**）に差分が無いか確認すること。

対象: iOS のみ。**DB / BE / API 契約の変更はゼロ**。

**2026-08-25 追記**: Q4・Q7 をユーザーに確認済み（`questions-requirements.md`）。Q4=A（既存踏襲・確定）、
Q7=B（FC名サジェストも今回まとめて追加・確定）。Q7 の確定に伴い T5 を追加した（下記）。

---

## 0. 現状把握（要約）

詳細は `requirements.md` §1。要点だけ:

- ツアー名サジェストは**実装済み**（`ApplicationFormView.swift:66-81` + `:243-249`）。欠けているのは
  アーティスト名（`:82-89`）と会場名（`:90-92`）
- 候補の元データ（`ApplicationStore.tours` / `.events`）は起動時に全件ロード済み。
  ローカルも BE もページング無し → **追加取得は不要**
- `Packages/Domain` には稼働中の XCTest がある（`swift test --package-path meigicho/Packages/Domain`）。
  振る舞いは Domain に寄せれば機械ゲートで検証できる
- `@State showTourSuggestions`（`:46`）は一度も読まれない死にコード（`docs/plans/application-edit/review.md:50` で指摘済み・未修正）

### なぜ BE 変更が不要か（検証済み根拠）

| 確認事項 | 結果 |
|---|---|
| 候補に必要なデータが端末にあるか | `GET /v1/tours` / `GET /v1/events` の結果が `ApplicationStore.tours/.events` に全件入る（`ApplicationStore.swift:55-69`）。ローカル SwiftData にも同じものがある |
| BE 側にページング上限があるか | 無い。`EventsService.list` は `ownerId` + `deletedAt: null` で `findMany`（`apps/api/src/events/events.service.ts:41-48`）。tours も同様 |
| 新しいレスポンス項目が要るか | 要らない。`artist_name_raw` / `venue_name_raw` は既にレスポンスに含まれ、iOS の Domain 型にマップ済み（`Models.swift:98,114`） |

→ Prisma / dto / controller / iOS Networking は**触らない**。

---

## 1. 設計判断

### D-1 マッチ規則は Domain の純粋関数に一本化する

`Packages/Domain/Sources/Domain/Models/InputSuggestion.swift`（新規）に

```
enum InputSuggestion {
    static let maxSuggestions = 5
    static func candidates(from values: [String]) -> [String]   // trim → 空除去 → 重複除去 → 昇順
    static func match(_ candidates: [String], query: String, limit: Int = maxSuggestions) -> [String]
}
```

を置き、ツアー名・アーティスト名・会場名の 3 フィールドが**同じ関数**を通る。
既存の `filteredTours`（`ApplicationFormView.swift:243-249`）もこれに置き換える。

- 却下 a: View に `filteredArtistNames` / `filteredVenueNames` をコピーして 3 つ並べる。同じ規則が 3 箇所に散り、
  片方だけ直る事故（BE-9 と同型の「経路が増えたのに検証が片方だけ」）を招く。XCTest からも触れない
- 却下 b: 規則ごと `ApplicationStore` のメソッドにする。`ApplicationStore` は `@MainActor @Observable` で
  Store の状態に依存しない純粋規則を混ぜる理由が無い。候補ソース（Store 依存）と規則（純粋）は分ける
- 根拠: `docs/plans/application-edit/` の `ApplicationEditPlanner`（Domain の純粋関数 + XCTest）と同じ形

### D-2 候補ソースは `ApplicationStore` の computed property として `existingTourNames` に並べる

```
public var existingArtistNames: [String]  // InputSuggestion.candidates(from: tours.map(\.artistNameRaw))
public var existingVenueNames: [String]   // InputSuggestion.candidates(from: events.map(\.venueNameRaw))
```

`existingTourNames`（`ApplicationStore.swift:305-307`）も `InputSuggestion.candidates(from:)` 経由に揃える
（tour.name は非空だが、規則を 2 種類にしない）。

- 却下: 候補を `@State` にキャッシュして `onAppear` で作る。`tours` / `events` は同期 pull で更新されるので
  開いている間に陳腐化する。`@Observable` の computed で毎回作れば整合が自動で取れる（NFR-3 の範囲内）

### D-3 ツアー候補タップ時にアーティスト名をオートフィルする

`ApplicationStore.artistName(forTourNamed:) -> String?`（名前完全一致・非空のときだけ返す）を追加し、
View のタップハンドラで `if let a = store.artistName(forTourNamed: tour) { artistName = a }`。

- 理由: 既存ツアー名で保存するとローカル find-or-create が入力アーティスト名を捨てる
  （`SwiftDataApplicationRepository.swift:247`・`requirements.md` §1.1）。オートフィルしないと
  「入力したのに保存後は別の値」になる
- 却下 a: 何もしない（Q5-B）。上記の黙った書き換えが残る
- 却下 b: 空でも上書き（Q5-C）。ユーザーの入力を消す
- 却下 c: find-or-create 側を直して入力値を優先させる。ツアー編集セマンティクス（FR-AE-9）と
  BE (`tours.service.ts:131`) の統一が必要でスコープが跳ね上がる（Q6-A）

### D-4 候補行は `DesignSystem` の共有 View に切り出す

`FormComponents.swift` に `FormSuggestionList(items:onSelect:)` を追加（行の `minHeight: 44`、
`theme.primary` 文字色、既存の候補行と同じ見た目）。3 フィールド + 将来の `TourFormView` / FC名で使い回す。

- 却下 a: `ApplicationFormView` の private helper。`docs/plans/tour-edit-and-delete/` が作る
  `TourFormView` でも同じ行が要る。Features 内で複製することになる
- 却下 b: 現状のまま `.padding(.vertical, 8)` を 3 箇所に書く。`docs/05:483` の「候補行（各44pt）」と
  ロードマップ 0-16（44pt タップ領域）を満たさない

### D-5 会場候補はツアー / アーティストで絞らない

全 `events` から作る（FR-4）。同じツアーの次の公演は**別会場**が普通なので、ツアーで絞ると
一番欲しい場面で候補が空になる。

- 却下: `tourName` に一致するツアーの公演だけに絞る。上記の理由で有害。かつツアー名未入力時の
  フォールバック規則が必要になり分岐が増える

### D-6 上限 5 件（ツアー名の既存挙動も変更する）

会場は履歴が増えると 2 文字クエリで数十件マッチする。候補行が公演日・代表者を画面外へ押し下げる。
ツアー名だけ無制限のまま残すと規則が割れる（Q3-C 却下）。

### D-7 サジェストは作成 / 編集の両モードで出す

`ApplicationFormView` は両モード共用で、ツアー名サジェストは既に両方で出ている。分岐を足さない。

### D-8 死にコード `showTourSuggestions` を削除する

`ApplicationFormView.swift:46`。今回サジェスト周りを触るので同時に消す（IOS-1 / 既指摘の後始末）。
**振る舞い変更なし**。

---

## 2. API 契約

**変更なし**。本計画は iOS 内で閉じる（§0 の根拠表）。BE / Prisma / `Packages/Networking` は
1 行も触らない。実装エージェントが「候補取得 API」を新設しようとしたら誤り。

---

## 3. 影響範囲

| 層 | ファイル | 変更 |
|---|---|---|
| DB | — | なし |
| BE | — | なし |
| iOS Domain | `Packages/Domain/Sources/Domain/Models/InputSuggestion.swift` | **新規**（D-1） |
| iOS Domain | `Packages/Domain/Sources/Domain/Stores/ApplicationStore.swift` | `existingArtistNames` / `existingVenueNames` / `artistName(forTourNamed:)` 追加、`existingTourNames` を D-2 に合わせる |
| iOS Domain (test) | `Packages/Domain/Tests/DomainTests/InputSuggestionTests.swift` | **新規**（AC-SG-01〜08-T） |
| iOS DesignSystem | `Packages/DesignSystem/Sources/DesignSystem/Components/FormComponents.swift` | `FormSuggestionList` 追加（D-4） |
| iOS Features | `Packages/Features/Sources/Features/Forms/ApplicationFormView.swift` | 3 フィールドの候補表示 + タップ時オートフィル + 死にコード削除 |
| iOS Domain | `Packages/Domain/Sources/Domain/Stores/IdentityStore.swift` | `existingFanClubNames` 追加（Q7-B確定） |
| iOS Features | `Packages/Features/Sources/Features/Forms/MembershipFormView.swift` | FC名欄（`:65`）の候補表示（Q7-B確定） |
| iOS Networking / DataStore | — | なし |
| docs | `docs/01-product-overview.md:186` / `docs/05-ios-client.md:482-484` / `docs/09-roadmap.md:82` 付近 / `docs/09-roadmap.md:78`（0-7） | サジェスト対象を4項目（ツアー名・アーティスト名・会場名・FC名）に更新。docs の「前方一致」を実装どおり「部分一致」へ訂正。0-11c 行を追加（Q8）。0-7（FC名サジェスト）を実装済みに更新 |

---

## 4. タスク分解

| ID | 内容 | 対象 | 担当 | 依存 |
|---|---|---|---|---|
| **T1** | **Red**: `InputSuggestionTests.swift` を先に書いて落とす（AC-SG-01〜08-T）。次に `InputSuggestion` を実装し、`ApplicationStore` に `existingArtistNames` / `existingVenueNames` / `artistName(forTourNamed:)` を追加、`existingTourNames` を `InputSuggestion.candidates(from:)` 経由に置換して Green | `Packages/Domain/**` | `swift-developer` (sonnet) | — |
| **T2** | `FormSuggestionList(items:onSelect:)` を `FormComponents.swift` に追加（行 `minHeight: 44`・`theme.primary`・既存候補行と同じタイポグラフィ） | `Packages/DesignSystem/**` | `swift-developer` (sonnet) | — |
| **T3** | `ApplicationFormView` 配線: ①`filteredTours` を `InputSuggestion.match(store.existingTourNames, query:)` に置換 ②アーティスト欄・会場欄に同じ候補表示を追加 ③候補行を `FormSuggestionList` に置換 ④ツアー候補タップ時に `artistName(forTourNamed:)` でオートフィル ⑤`showTourSuggestions` 削除 | `Packages/Features/Sources/Features/Forms/ApplicationFormView.swift` | `swift-developer` (sonnet) | T1, T2 |
| **T5** | **Red**: `IdentityStoreTests` 等に `existingFanClubNames` のテスト（AC-SG-17-T）を先に書いて落とす。次に `IdentityStore` に `existingFanClubNames`（`InputSuggestion.candidates(from:)` 経由）を追加して Green。続けて `MembershipFormView.swift:65` のFC名欄に `InputSuggestion.match` + `FormSuggestionList` を配線（AC-SG-18-M） | `Packages/Domain/Sources/Domain/Stores/IdentityStore.swift`, `Packages/Features/Sources/Features/Forms/MembershipFormView.swift` | `swift-developer` (sonnet) | T1（`InputSuggestion`）, T2（`FormSuggestionList`） |
| **T4** | docs 更新（`docs/01:186` / `docs/05:482-484` / `docs/09` 0-11c 追記・0-7 実装済み化）。`docs/plans/STATUS.md` に本計画を 1 行追記 | `docs/**` | 任意（planner / developer） | T3, T5 の実装内容確定後 |

### 並列実行可能なタスク

- **T1 と T2 は並列可**（別パッケージ・別ファイル・依存なし）
- **T4 は T1/T2 と並列可**（docs のみ）
- **T3 は T1・T2 の完了後**（両方の API を使う）
- **T5 は T1・T2 の完了後、T3 と並列可**（`ApplicationFormView.swift` と `MembershipFormView.swift` は別ファイル）

### 直列必須 / 競合注意

- `ApplicationStore.swift` は **T1 だけ**が触る。ただし未実装の `docs/plans/tour-edit-and-delete/` の
  T4 が**同じファイル**を触る計画になっている（`tour-edit-and-delete/plan.md:143`）。
  **2 つの計画を同時に走らせない**。どちらかを先に main へ入れてからもう一方を開始する
- `ApplicationFormView.swift` は T3 だけ。他計画は触らない
- `FormComponents.swift` は T2 だけ
- `IdentityStore.swift` / `MembershipFormView.swift` は T5 だけ
- `tour-edit-and-delete` 実装後、`TourFormView` のアーティスト名欄に `FormSuggestionList` +
  `existingArtistNames` を足すのは**フォローアップ**（本計画には含めない）

---

## 5. 受入基準 → テストケース

### 5.1 自動（`swift test --package-path meigicho/Packages/Domain`）

`Packages/Domain/Tests/DomainTests/InputSuggestionTests.swift`。**先に書いて落とすこと（Red→Green）**。

| AC-ID | テストケース | 期待 |
|---|---|---|
| AC-SG-01-T | `ApplicationStore` に `artistNameRaw` が `["STELLARIS", "STELLARIS", "", "  ", "AURORA"]` のツアーを積む | `existingArtistNames == ["AURORA", "STELLARIS"]` |
| AC-SG-02-T | `venueNameRaw` が `["マリンメッセ福岡", "", "東京ドーム", "マリンメッセ福岡"]` の公演を積む | `existingVenueNames == ["マリンメッセ福岡", "東京ドーム"]` を昇順で（順序はロケール依存にしないよう `sorted()` の結果をそのまま期待値に書く） |
| AC-SG-03-T | `match(["STELLARIS ARENA TOUR 2026"], query: "arena")` | 1 件返る（部分一致・大小無視） |
| AC-SG-04-T | `match(["STELLARIS"], query: "stellaris")` | 空（完全一致は大小無視で除外） |
| AC-SG-05-T | `match(candidates, query: "")` / `query: "   "` | 空配列 |
| AC-SG-06-T | 7 件ヒットするクエリ | 5 件だけ返る |
| AC-SG-07-T | ツアー `("TOUR A", artist: "AURORA")` / `("TOUR B", artist: "")` | `artistName(forTourNamed: "TOUR A") == "AURORA"` / `forTourNamed: "TOUR B"` は `nil` / 未知名は `nil` |
| AC-SG-08-T | 既存 `filteredTours` と同じ入力（ツアー 3 件・クエリ 1 件）で `match(existingTourNames, query:)` | 従来と同じ配列（回帰。5 件超のケースのみ FR-7 で意図的に差が出ることをコメントで明記） |

既存テストの回帰も必須: `StoreTests.swift` / `ApplicationStoreNetworkTests.swift` を含め
Domain パッケージ全緑。

### 5.2 手動（iOS・シミュレータ）

前提: 申込を 3 件以上作り、アーティスト名 2 種・会場名 6 種以上を含めておく。

| AC-ID | 手順 | 期待 |
|---|---|---|
| AC-SG-09-M | 申込タブ → ＋ → アーティスト欄に既存アーティストの 1 文字を入力 → 候補をタップ | 候補が出る / タップで欄が埋まる / タップ後は完全一致で候補が消える |
| AC-SG-10-M | 同じフォームの会場欄で 1 文字入力 → 候補をタップ | 同上 |
| AC-SG-11-M | ツアー名欄に既存ツアーの一部を入力 → 候補をタップ | ツアー名が入り、**アーティスト欄がそのツアーの値で埋まる**。アーティスト名が空のツアーではアーティスト欄が変化しない |
| AC-SG-12-M | 申込を全削除（またはサインアウト直後の空状態）でフォームを開き各欄に入力 | どの欄にも候補が出ない・空の候補枠も出ない |
| AC-SG-13-M | 申込詳細 → 編集 でフォームを開く → アーティスト欄を全消しして 1 文字入力 | 候補が出る（編集モードでも動く）。開いた直後（初期値のまま）は候補が出ない |
| AC-SG-14-M | 機内モード ON で AC-SG-09-M を再実行 | 候補が出る |
| AC-SG-15-M | 候補行の右端（文字の無い余白）をタップ | 選択される（行全体がタップ領域） |
| AC-SG-16-M | 会場欄に多くヒットする 1 文字（例「東」）を入力 | 候補は 5 件まで。公演日・代表者が画面外に押し出されない |

---

## 6. 検証ゲート（完了条件）

```bash
swift test --package-path /Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain

xcodebuild -project /Users/yuyamorishita/オタ活アプリ/meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
```

BE は変更しないので `apps/api` のゲートは対象外（変更していないことを `git status` で確認する）。
`project.yml` / `xcodegen` は新規ファイルが SPM パッケージ配下のみなので**再生成不要**（IOS-8 の対象外。
`Package.swift` のターゲット構成も変えない）。

---

## 7. リスクと既知の落とし穴

| # | リスク | 対策 |
|---|---|---|
| R-1 | 3 フィールドで規則がコピペされる | D-1 の共通関数を必ず経由。レビューで `localizedCaseInsensitiveContains` が View に残っていないか grep |
| R-2 | 空文字候補で空ボタンが並ぶ | `candidates(from:)` で trim + 空除去（AC-SG-01/02-T） |
| R-3 | `ApplicationStore.swift` が `tour-edit-and-delete` と衝突 | §4「直列必須」。同時に走らせない |
| R-4 | `Features` が `DataStore` を import する（IOS-5） | View が触るのは `ApplicationStore` と `DesignSystem` のみ |
| R-5 | 候補表示でキーボードが隠れる / スクロールが飛ぶ | 既存のツアー名候補と同じ配置（`FormRow` 内・入力欄の直下）に揃える。`ScrollViewReader` 等は導入しない |
| R-6 | ツアー候補タップ時のオートフィルが編集モードで意図しない上書きになる | 対象は「ユーザーが候補をタップした瞬間」だけ。`onAppear` や `onChange` では発火させない |
| R-7 | 実装者が「候補取得 API」を作ろうとする | §2 に明記。BE 変更ゼロ |

---

## 8. ハンドオフ（委譲プロンプト案）

### T1 → `swift-developer`（model: sonnet）

> まず `/Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md` を読み、従うこと。
>
> 【目的】申込フォームの入力サジェスト（ツアー名 / アーティスト名 / 会場名）の候補計算を Domain の純粋関数に
> 一本化する。UI は別タスクで配線する。
> 【対象】`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain`
> 【計画】`/Users/yuyamorishita/オタ活アプリ/docs/plans/input-history-suggestions/plan.md` の D-1 / D-2 / D-3、
> 受入基準は同 `requirements.md` §6 の AC-SG-01〜08-T。
> 【やること】
> 1. `Tests/DomainTests/InputSuggestionTests.swift` を先に書き、`swift test` が**落ちること**を確認する（Red）
> 2. `Sources/Domain/Models/InputSuggestion.swift` を新規作成（`candidates(from:)` / `match(_:query:limit:)` /
>    `maxSuggestions = 5`）
> 3. `Sources/Domain/Stores/ApplicationStore.swift` に `existingArtistNames` / `existingVenueNames` /
>    `artistName(forTourNamed:) -> String?` を追加し、既存 `existingTourNames`（`:305-307`）を
>    `InputSuggestion.candidates(from:)` 経由に置き換える
> 【従う既存例】`Sources/Domain/Models/ApplicationEditPlanner.swift`（Domain の純粋関数 + XCTest の形）、
> `Tests/DomainTests/ApplicationEditPlannerTests.swift`
> 【やらないこと】View / DesignSystem / Networking / DataStore / apps/api は触らない。UI 配線もしない。
> 表記ゆれ正規化・頻度順ソートは実装しない。`.claude/rules/feedback_review_patterns.md` の IOS-5 を守る
> 【完了条件】`swift test --package-path /Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain` が全緑
> 【報告】日本語で ①変更ファイル（file:line）②実行した検証コマンドと結果 ③残課題

### T2 → `swift-developer`（model: sonnet、T1 と並列）

> 【目的】入力候補行の共通 View を DesignSystem に用意する（現状は `ApplicationFormView.swift:70-80` に
> 直書きされ、タップ領域が 44pt 未満）。
> 【対象】`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/DesignSystem/Sources/DesignSystem/Components/FormComponents.swift`
> 【やること】`FormSuggestionList(items: [String], onSelect: (String) -> Void)` を追加。各行は
> `Button` + `.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)`、`DSFont.body`、
> 文字色は `theme.primary`（既存 `ApplicationFormView.swift:70-80` と同じ見た目・同じ環境値の取り方）。
> `items` が空なら何も描画しない。
> 【やらないこと】既存 `FormTextField` / `FormRow` / `FormCard` のシグネチャを変えない。Features は触らない
> 【完了条件】`xcodebuild ... build` が BUILD SUCCEEDED（`CLAUDE.md` の iOS コマンド）
> 【報告】日本語で ①変更 ②検証結果 ③残課題

### T3 → `swift-developer`（model: sonnet、T1 / T2 完了後）

> 【目的】申込フォームのツアー名 / アーティスト名 / 会場名を、過去履歴から選んで入力できるようにする。
> 【対象】`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Features/Sources/Features/Forms/ApplicationFormView.swift`
> 【計画】`docs/plans/input-history-suggestions/plan.md` §4 T3・受入基準 AC-SG-09〜16-M
> 【やること】
> 1. `filteredTours`（`:243-249`）を `InputSuggestion.match(applicationStore.existingTourNames, query: tourName)` に置換
> 2. アーティスト欄（`:82-89`）と会場欄（`:90-92`）に同じ形の候補表示を追加（候補ソースは
>    `existingArtistNames` / `existingVenueNames`）
> 3. 候補行の描画を `FormSuggestionList` に置き換える（3 箇所とも）
> 4. ツアー候補をタップしたとき、`applicationStore.artistName(forTourNamed:)` が非 nil ならアーティスト欄に代入する
> 5. 未使用の `@State showTourSuggestions`（`:46`）を削除する
> 【やらないこと】公演名欄・FC名（`MembershipFormView`）は対象外。`ApplicationStore` / `Domain` /
> `DesignSystem` / BE は変更しない（T1・T2 で確定済み）。`DataStore` / `Networking` を import しない（IOS-5）
> 【完了条件】`xcodebuild ... build` が BUILD SUCCEEDED + AC-SG-09〜16-M の手動確認手順を実施して結果を報告
> 【報告】日本語で ①変更（file:line）②ビルド結果 ③手動確認 AC ごとの結果 ④残課題

### T5 → `swift-developer`（model: sonnet、T1 / T2 完了後、T3 と並列可）

> まず `/Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md` を読み、従うこと。
>
> 【目的】会員情報フォームのFC名欄でも、過去入力履歴から選んで入力できるようにする（Q7-B確定）。
> 【対象】`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain/Sources/Domain/Stores/IdentityStore.swift`、
> `/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Features/Sources/Features/Forms/MembershipFormView.swift`
> 【計画】`docs/plans/input-history-suggestions/plan.md` T5・受入基準 AC-SG-17-T/18-M
> 【やること】
> 1. Domain の既存テストファイル（`IdentityStore` 関連。`Tests/DomainTests/` から grep して特定）に
>    `existingFanClubNames` のテストを先に書き、落ちることを確認する（Red、AC-SG-17-T:
>    重複除去・空白のみ除外・昇順）
> 2. `IdentityStore` に `existingFanClubNames: [String]` を追加（`InputSuggestion.candidates(from:
>    memberships.map(\.fanClubNameRaw))` 相当。`IdentityStore` 内の該当プロパティ名を実装前に確認する）
> 3. `MembershipFormView.swift:65` のFC名欄に、`ApplicationFormView`（T3）と同じ形で
>    `InputSuggestion.match(identityStore.existingFanClubNames, query:)` + `FormSuggestionList` を配線
> 【従う既存例】T1 が作る `InputSuggestion`（`Packages/Domain/Sources/Domain/Models/InputSuggestion.swift`）、
> T2 が作る `FormSuggestionList`（`FormComponents.swift`）、T3 のツアー名/アーティスト名/会場名の配線パターン
> 【やらないこと】`ApplicationFormView.swift` / `ApplicationStore.swift` は触らない（T3の担当）。
> FC名候補をタップしたときの他欄への自動反映は行わない（FR-6はツアー名専用、FC名には対応する連動先が無い）
> 【完了条件】`swift test --package-path .../Domain` 全緑 + `xcodebuild ... build` が BUILD SUCCEEDED +
> AC-SG-18-M の手動確認手順を実施して結果を報告
> 【報告】日本語で ①変更（file:line）②検証結果 ③手動確認結果 ④残課題

### レビュー

実装完了後、**別セッション**で `code-reviewer`（model: sonnet で可 — iOS 単層・契約変更なし）を呼ぶ。
差分範囲は本ブランチ全差分、結果は `docs/plans/input-history-suggestions/review.md` へ。
観点: IOS-1 / IOS-4 / IOS-5、規則のコピペ有無（R-1）、`docs` との整合、スコープ外（BE・公演名・FC名）への波及なし。
