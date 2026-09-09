# event-name-suggestion — Workflow Plan

`requirements.md` の受入基準を実装タスクへ分解する。着手前に `questions-requirements.md` の
**Q1・Q4（仮回答）**をユーザーに確認すること。Q4 が A（他欄を補完しない）になった場合の縮小手順は
`questions-requirements.md` Q4 末尾に書いた。

対象: **iOS のみ**。DB / BE / API 契約の変更はゼロ。

---

## 0. 現状把握（要約）

詳細は `requirements.md` §1。要点:

- **起票時の前提は誤りだった**。`input-history-suggestions`（0-11d）は**すでに main にマージ済み**
  （`c1658d1 Merge pull request #19`）。`tour-edit-and-delete`（#17）/ `membership-full-number`（#18）も同様。
  → **「2 計画を同時に走らせない」という起票時の懸念は消滅**（§4.3 で再確認する）
- 共有部品は**すでに存在する。新規作成せず再利用する**:
  - `InputSuggestion.candidates(from:)` / `.match(_:query:limit:)` / `.maxSuggestions = 5`
    （`Packages/Domain/Sources/Domain/Models/InputSuggestion.swift:12-27`）
  - `FormSuggestionList(items:onSelect:)`（`Packages/DesignSystem/Sources/DesignSystem/Components/FormComponents.swift:96-123`。`minHeight: 44`・空配列なら非描画）
- 未対応は**公演名欄だけ**（`ApplicationFormView.swift:57-64` が素の `FormTextField`）。
  ツアー名 `:69` / アーティスト `:78` / 会場 `:87` / FC名（`MembershipFormView.swift:73`）は配線済み
- Domain には稼働中の XCTest がある（`InputSuggestionTests.swift`。パッケージ全体で 287 件緑）

### なぜ BE 変更が不要か（検証済み根拠）

| 確認事項 | 結果 |
|---|---|
| 候補に必要なデータが端末にあるか | `ApplicationStore.events` / `.tours` に全件ロード済み（`ApplicationStore.swift:55-69`）。ローカル SwiftData にも同じものがある |
| BE / ローカルにページング上限があるか | 無い。`listTours` / `listEvents` は `deletedAt == nil` の全件。`EventsService.list` も `ownerId` + `deletedAt: null` の `findMany`（`apps/api/src/events/events.service.ts:41-48`） |
| 新しいレスポンス項目が要るか | 要らない。`name` / `venue_name_raw` / `event_date` / `updated_at` はすべてレスポンスにあり `EventEntity` にマップ済み（`Models.swift:110-138`） |
| 公演の名前ベース find-or-create が要るか | **要らない**（Q2-A。スコープ外。`requirements.md` §1.1） |

→ Prisma / dto / controller / `Packages/Networking` / `Packages/DataStore` は**触らない**。

---

## 1. 設計判断

### D-1 候補ソースは全公演。ツアーで絞らない

`ApplicationStore.existingEventNames`（全 `events` の `name`）を使う（FR-ES-2）。

- 却下 a: ツアー名欄が非空ならそのツアーの公演に絞る（未入力なら全履歴）。フォームは公演名→ツアー名の
  順（`ApplicationFormView.swift:57,65`）で、公演名入力時にツアー名は空であることが支配的 →
  絞り込み条件が成立しない場面が支配的なのに二段規則を抱える
- 却下 b: ツアーで絞る（未入力なら候補ゼロ）。主用途「同じ公演に別名義でもう 1 件」でツアー名は空 → 候補ゼロ
- 補足: 同一ツアー内の他公演は「別都市＝別文字列」で再利用価値が低い。会場名で絞り込みを却下した
  `input-history-suggestions` D-5 と同じ構図

### D-2 公演名の候補だけ「公演日の新しい順」にし、並び順は候補ソース側の責務にする

`InputSuggestion` に**順序保持版**を足す（規則ではなく並びの問題なので `match` は変えない）:

```swift
/// 呼び出し側が決めた並び順を保持したまま候補一覧を作る:
/// trim → 空除去 → 重複除去（先勝ち）→ 入力順を保持（FR-ES-4）
public static func candidates(fromOrdered values: [String]) -> [String]
```

`match(_:query:limit:)` は `filter` + `prefix` なので**入力配列の順序をそのまま保つ**
（`InputSuggestion.swift:23-26`）→ マッチ規則を 1 実装に保ったまま並びだけ差し替えられる（NFR-1 維持）。

- 理由: 公演名は「ツアー名 + 都市」で共通接頭辞が長く、既存の `candidates(from:)`（`sorted()` 昇順）+
  上限 5 件だと**古い年のツアーの公演名が 5 枠を占有**して最新ツアーの候補が出ない（`requirements.md` §1.2）
- 却下 a: 既存の `candidates(from:)`（昇順）をそのまま使う。上記の事故が主用途で必ず起きる
- 却下 b: `match` に「関連度順」を実装する。5 フィールドで共有している規則に公演名専用の分岐を持ち込む
  ことになり NFR-1 に反する。並びは**候補ソース側**で決めるのが正しい層
- 却下 c: 5 フィールドすべてを「最近使った順」に変える。他 4 フィールドは共通接頭辞が短く問題が
  顕在化していないため、回帰リスク（既存テスト 287 件のうち昇順を期待するもの）に見合わない。
  統一するかはフォローアップ（`requirements.md` §4）

### D-3 公演名候補タップ時は「空の欄だけ」補完する

`ApplicationStore.eventAutofill(forEventNamed:) -> EventNameAutofill?` を追加し、View 側で
**空欄のときだけ**代入する（FR-ES-5）。

```swift
public struct EventNameAutofill: Equatable, Sendable {
    public let tourName: String?      // 公演が属するツアーの name（空なら nil）
    public let artistNameRaw: String? // 同ツアーの artistNameRaw（空なら nil）
    public let venueNameRaw: String?  // 公演の venueNameRaw（空なら nil）
}
```

- 理由 1: 主用途「同じ公演に別名義でもう 1 件」で、公演名だけ埋めても残り 3 欄の手入力が残る
- 理由 2: ツアー名が空のまま保存されると `trimmedTourName` が**公演名をツアー名として使う**
  （`ApplicationFormView.swift:267-270`）ため公演ごとに別ツアーが増える。空欄補完はこれを自然に防ぐ
- 理由 3: 「空の欄だけ」にすると**編集モードでは実質何も起きない**（各欄が初期値で埋まっている）ため、
  FR-AE-7/8 の波及セマンティクス（`ApplicationFormView.swift:59-63, 79-83`）に**モード分岐なしで**触れずに済む
- 却下 a: 何もしない（公演名だけ）。実装は最小だが体感価値が小さい
- 却下 b: 空でなくても上書き。編集モードで会場・アーティストを黙って書き換え、他の申込へ波及する
- 却下 c: 公演日も補完する。作成モードでは `today` が入っていて「空欄のみ」規則では触れないうえ、
  過去公演の日付を引き継ぎたいかは意図依存（Q4 参照）
- 根拠となる前例: `artistName(forTourNamed:)` + View 側 `if let`（`ApplicationStore.swift:319-324`,
  `ApplicationFormView.swift:69-74`）＝ `input-history-suggestions` D-3 と同じ形

### D-4 並び順の実体は `ApplicationStore` の private helper 1 本にする

`existingEventNames`（候補）と `eventAutofill(forEventNamed:)`（補完元の特定）で**同じ順序**を使う
（FR-ES-6: 同名が複数あるとき「最も新しい 1 件」の定義が 2 箇所でズレないこと）。

```swift
/// FR-ES-4: eventDate 降順（nil は最後）→ 同値は updatedAt 降順
private var eventsByRecency: [EventEntity]
```

- 却下: 候補は sorted、補完は `events.first(where:)`。`events` の並びは repository 依存で不定なので
  「同名のどれが補完元か」が実行ごとに変わりうる

### D-5 UI 部品・マッチ規則・タップ領域は既存のまま流用する

`FormSuggestionList` をそのまま使う（NFR-5）。新しい行 View を作らない。配置は既存 4 フィールドと同じ
`FormRow` 内・入力欄の直下。公演名行はヒント（FR-AE-7）を挟むので、**ツアー名行と同じ並び
（TextField → Hint → SuggestionList）**に揃える。

---

## 2. API 契約

**変更なし**。本計画は iOS 内で閉じる（§0 の根拠表）。BE / Prisma / `Packages/Networking` /
`Packages/DataStore` は 1 行も触らない。実装エージェントが「候補取得 API」や「公演の名前ベース
find-or-create」を作ろうとしたら誤り（`requirements.md` §1.1・§4）。

---

## 3. 影響範囲

| 層 | ファイル | 変更 |
|---|---|---|
| DB | — | なし |
| BE | — | なし |
| iOS Domain | `Packages/Domain/Sources/Domain/Models/InputSuggestion.swift` | `candidates(fromOrdered:)` を**追加**（既存 2 関数は変更しない） |
| iOS Domain | `Packages/Domain/Sources/Domain/Stores/ApplicationStore.swift` | `existingEventNames` / private `eventsByRecency` / `eventAutofill(forEventNamed:)` を追加。`EventNameAutofill` 構造体をファイル末尾（`ApplicationDisplay` の並び）に追加。**既存の `existingTourNames` / `existingArtistNames` / `existingVenueNames` は変更しない** |
| iOS Domain (test) | `Packages/Domain/Tests/DomainTests/InputSuggestionTests.swift` | AC-ES-01〜05-T を追記（新規ファイルは作らない。既存ファイルに公演名セクションを足す） |
| iOS DesignSystem | — | なし（`FormSuggestionList` を再利用） |
| iOS Features | `Packages/Features/Sources/Features/Forms/ApplicationFormView.swift` | 公演名行に `FormSuggestionList` + `filteredEventNames` + `applyEventAutofill(for:)` を追加 |
| iOS Networking / DataStore | — | なし |
| docs | `docs/01-product-overview.md:186` / `docs/05-ios-client.md`（サジェスト対象の記述）/ `docs/09-roadmap.md`（0-11e 追記・Phase 0 合計）/ `docs/plans/STATUS.md` | サジェスト対象に公演名を追加。並び順が公演名だけ「新しい順」であることを明記 |

---

## 4. タスク分解

| ID | 内容 | 対象 | 担当 | 依存 |
|---|---|---|---|---|
| **T1** | **Red→Green（Domain）**: `InputSuggestionTests.swift` に AC-ES-01〜05-T を先に書いて落とす → `InputSuggestion.candidates(fromOrdered:)`、`ApplicationStore.eventsByRecency` / `existingEventNames` / `eventAutofill(forEventNamed:)`、`EventNameAutofill` を実装して Green | `Packages/Domain/**` | `swift-developer` (sonnet) | — |
| **T2** | **配線（Features）**: 公演名行に `FormSuggestionList(items: filteredEventNames)` を追加し、タップで `eventName` 代入 + 空欄のみオートフィル（`applyEventAutofill`）。手動確認 AC-ES-06〜13-M | `Packages/Features/Sources/Features/Forms/ApplicationFormView.swift` | `swift-developer` (sonnet) | **T1** |
| **T3** | docs 更新（`docs/01:186` の Note に公演名を追加 / `docs/05` のサジェスト記述 / `docs/09` に 0-11e を追加し Phase 0 合計を補正 / `docs/plans/STATUS.md` に 1 行） | `docs/**` | 任意（planner / developer） | 仕様確定後（T1/T2 と並列可） |

### 4.1 並列実行可能なタスク

- **T3 は T1 / T2 と並列可**（docs のみ・コードに触れない）
- **T1 → T2 は直列必須**（T2 は T1 が追加する Domain API を呼ぶ）。本計画のコード変更は 2 ファイルだけで
  並列の旨みが無いため、**T1・T2 を同一エージェントに連続で任せてもよい**（その場合も
  「Red を先に書いて落とす」ことは省略しない）

### 4.2 直列必須 / 競合注意

- `ApplicationStore.swift` は T1 だけ、`ApplicationFormView.swift` は T2 だけが触る
- `InputSuggestion.swift` は**追加のみ**。既存 `candidates(from:)` / `match` のシグネチャと挙動を変えない
  （4 フィールドが依存している。変えると既存テストと 4 画面が巻き添えになる）
- `FormComponents.swift` は触らない

### 4.3 他計画との衝突チェック（2026-08-26 実測）

| 計画 | 状態 | 衝突 |
|---|---|---|
| `input-history-suggestions` | **main にマージ済み**（PR #19） | なし（本計画はその後続） |
| `tour-edit-and-delete` | **マージ済み**（PR #17） | なし |
| `membership-full-number` | **マージ済み**（PR #18） | なし |

→ 現時点で `ApplicationStore.swift` / `ApplicationFormView.swift` を触る未実装計画は無い。
着手直前に `ls docs/plans/` と `git log --oneline -5` で再確認すること。

---

## 5. 受入基準 → テストケース

### 5.1 自動（`swift test --package-path meigicho/Packages/Domain`）

追記先: `Packages/Domain/Tests/DomainTests/InputSuggestionTests.swift`。**先に書いて落とすこと（Red→Green）**。
既存テスト（`store.tours` / `store.events` に直接代入する形・`InputSuggestionTests.swift:11-30`）に倣う。

| AC-ID | テストケース | 期待 |
|---|---|---|
| AC-ES-01-T | `candidates(fromOrdered: ["B", "", "  ", "A", "B"])` | `["B", "A"]`（入力順保持・重複は先勝ち・空除去。**昇順にしない**） |
| AC-ES-02-T | `store.events` に 公演日 2026-10-05 / 2026-08-01 / `nil` の 3 公演を（配列順はバラバラに）積む | `existingEventNames` が「10-05, 08-01, nil の公演」の順 |
| AC-ES-03-T | 同名 `"X 福岡公演"` の公演を日付違いで 2 件積む | `existingEventNames` に `"X 福岡公演"` は 1 回だけ |
| AC-ES-04-T | 公演 `("X 福岡公演", venue: "マリンメッセ福岡", tour: ("T", artist: "A"))` ほか | `eventAutofill(forEventNamed: "X 福岡公演")` が `(tourName: "T", artistNameRaw: "A", venueNameRaw: "マリンメッセ福岡")`。venue が `""` なら該当項目のみ `nil`。`tours` に該当ツアーが無ければ tourName / artistNameRaw が `nil` で venue のみ入る（E-6）。未知名は戻り値ごと `nil`。同名が複数なら**最も新しい公演**の値を返す（FR-ES-6） |
| AC-ES-05-T | `InputSuggestion.match(store.existingEventNames, query: "福岡")` / `query: ""` / 6 件ヒットするクエリ / クエリと完全一致する候補 | 部分一致・大小無視で返る / 空配列 / 5 件だけ（**新しい順の先頭 5 件**） / 完全一致は除外 |

既存テストの回帰も必須: Domain パッケージ全緑（現状 287 件）。

### 5.2 手動（iOS・シミュレータ）

前提データ: 同じアーティストで**年違いのツアー 2 本**（例 `... TOUR 2025` に公演 5 件、`... TOUR 2026` に
公演 2 件）を作り、公演名は「ツアー名 -都市公演-」形式で入れる。会場・アーティストも埋めておく。

| AC-ID | 手順 | 期待 |
|---|---|---|
| AC-ES-06-M | 申込タブ → ＋ → 公演名欄に「福岡」と入力 → 候補をタップ | 候補が出る / タップで欄が埋まる / タップ後は完全一致で候補が消える |
| AC-ES-07-M | 公演名欄にツアー名部分（例「STELLARIS AR」）を入力 | 候補 5 件のうちに **2026 の公演**が含まれる（2025 の 5 件で埋まらない）＝ D-2 の効果 |
| AC-ES-08-M | 作成フォームを開き、他の欄に触れずに公演名候補をタップ | ツアー名・アーティスト・会場が埋まる。**公演日は today のまま**変化しない |
| AC-ES-09-M | 作成フォームでツアー名だけ先に手入力 → 公演名候補をタップ | ツアー名は書き換わらない。アーティスト・会場だけ埋まる |
| AC-ES-10-M | 同じ公演を参照する申込が 2 件以上ある申込を編集 → 公演名候補をタップ | 各欄は初期値のまま書き換わらず、公演名だけ変わる。波及ヒント「この公演を参照する他 N 件にも反映されます。」が出る |
| AC-ES-11-M | 申込 0 件の状態（またはサインアウト直後）で公演名欄に入力 | 候補も空の枠も出ない |
| AC-ES-12-M | 機内モード ON で AC-ES-06-M を再実行 | 候補が出る |
| AC-ES-13-M | 候補行の右端（文字の無い余白）をタップ | 選択される |

> `input-history-suggestions` の手動確認（AC-SG-09〜16-M / 18-M）は
> `docs/plans/input-history-suggestions/review.md` の軽微指摘 1 のとおり**未実施のまま**。
> 同じフォームを開くので、本計画の手動確認のついでに実施して結果を報告するとよい（必須ではない）。

---

## 6. 検証ゲート（完了条件）

```bash
swift test --package-path /Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain

xcodebuild -project /Users/yuyamorishita/オタ活アプリ/meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
```

- BE は変更しないので `apps/api` のゲートは対象外。`git status` で `apps/api/` に差分が無いことを確認する
- `project.yml` / `xcodegen` の再生成は**不要**（新規ファイルを作らず、SPM パッケージ内の既存ファイルへの
  追記のみ。`Package.swift` のターゲット構成も変えない → IOS-8 の対象外）

---

## 7. リスクと既知の落とし穴

| # | リスク | 対策 |
|---|---|---|
| R-1 | 実装者が既存の `candidates(from:)`（昇順）を流用して D-2 が消える | AC-ES-02-T が昇順だと落ちるように書く（期待値を「日付順」にし、辞書順と一致しないデータを使う） |
| R-2 | マッチ規則が View にコピーされる（IOS 既知パターン・R-1 相当） | `InputSuggestion.match` のみを使う。レビューで `localizedCaseInsensitiveContains` が `Features` 配下に無いか grep |
| R-3 | オートフィルが**非空**の欄を上書きする | View 側は必ず「trim して空のときだけ代入」。AC-ES-09-M / AC-ES-04-T |
| R-4 | 実装者が「同じ公演に紐づける」ため公演の名前ベース find-or-create を足す | §2 / `requirements.md` §1.1 に明記。`DataStore` / `apps/api` は 1 行も触らない |
| R-5 | 編集モードで空欄補完が FR-AE-7/8 経由で他申込に波及する | 「空の欄だけ」なので編集モードでは通常発火しない。会場が空だった申込では発火しうる → 既存の波及ヒントが自動表示される（E-8・AC-ES-10-M で確認） |
| R-6 | `sorted(by:)` の比較が strict weak ordering を壊す（`nil` 混在の日付比較） | D-4 の 1 本の helper に閉じ込め、`nil` 混在データを含む AC-ES-02-T で検証する |
| R-7 | `eventAutofill` の名前比較が trim されておらず、末尾空白付きの公演名で永久に nil になる | 候補は trim 済み文字列なので、比較も**両辺 trim** する（AC-ES-04-T に空白付きデータを 1 件混ぜる） |
| R-8 | `existingEventNames` を `@State` にキャッシュして同期 pull 後に陳腐化する | 既存 4 フィールドと同じく `@Observable` の computed で毎回計算する（NFR-3） |

---

## 8. ハンドオフ（委譲プロンプト案）

### T1 → `swift-developer`（model: sonnet）

> まず `/Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md` を読み、従うこと。
>
> 【目的/背景】申込フォームの「公演名」欄に過去入力履歴からのサジェストを追加する（roadmap 0-11e）。
> 本タスクはその候補計算とオートフィル解決を Domain に用意する部分。UI 配線は後続タスク。
> 【対象】`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain`
> 【計画】`/Users/yuyamorishita/オタ活アプリ/docs/plans/event-name-suggestion/plan.md` の D-2 / D-3 / D-4、
> 受入基準は同ディレクトリ `requirements.md` §6 の AC-ES-01〜05-T。
> 【やること】
> 1. `Tests/DomainTests/InputSuggestionTests.swift` に公演名セクションを**先に**書き、`swift test` が
>    落ちることを確認する（Red）。新規テストファイルは作らない
> 2. `Sources/Domain/Models/InputSuggestion.swift` に `candidates(fromOrdered values: [String]) -> [String]`
>    を**追加**する（trim → 空除去 → 重複除去（先勝ち）→ **入力順を保持**）。既存の `candidates(from:)` と
>    `match(_:query:limit:)` は**シグネチャも挙動も変えない**（4 フィールドが依存している）
> 3. `Sources/Domain/Stores/ApplicationStore.swift` に以下を追加する
>    - private `var eventsByRecency: [EventEntity]` — `eventDate` 降順・`nil` は最後・同値は `updatedAt` 降順
>    - `public var existingEventNames: [String]` — `InputSuggestion.candidates(fromOrdered: eventsByRecency.map(\.name))`
>    - `public func eventAutofill(forEventNamed name: String) -> EventNameAutofill?` — 名前を**両辺 trim して
>      完全一致**させ、`eventsByRecency` の先頭にヒットしたものを採用。`tour(for:)` でツアーを解決し、
>      `tourName` / `artistNameRaw` / `venueNameRaw` を返す。**空文字は nil に落とす**。ツアーが解決できない
>      ときは tourName / artistNameRaw を nil にして venue のみ返す。一致なしは戻り値ごと nil
>    - `public struct EventNameAutofill: Equatable, Sendable { tourName / artistNameRaw / venueNameRaw: String? }`
>      をファイル末尾（既存 `ApplicationDisplay` の並び）に置く
> 【従う既存例】`ApplicationStore.swift:305-324`（`existingTourNames` / `existingArtistNames` /
> `existingVenueNames` / `artistName(forTourNamed:)`）、`InputSuggestionTests.swift:9-30`（`store.tours` /
> `store.events` に直接代入するテストの書き方）
> 【制約・やらないこと】View / DesignSystem / Networking / DataStore / `apps/api` は触らない。
> 既存 4 フィールドの候補（昇順）を変えない。表記ゆれ正規化・頻度順ソート・キャッシュは実装しない。
> 公演の名前ベース find-or-create（同じ公演への紐づけ）は**スコープ外**。
> `.claude/rules/feedback_review_patterns.md` の IOS-5 を守る
> 【完了条件】`swift test --package-path /Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain` が全緑
> （既存 287 件の回帰を含む）
> 【報告】日本語で ①変更ファイル（file:line）②実行した検証コマンドと結果（Red の失敗内容も）③残課題

### T2 → `swift-developer`（model: sonnet、T1 完了後）

> まず `/Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md` を読み、従うこと。
>
> 【目的/背景】申込フォームの「公演名」欄で、過去に入力した公演名を選んで即入力できるようにする
> （roadmap 0-11e）。ツアー名・アーティスト・会場・FC名は実装済みで、公演名だけが未対応。
> 【対象】`/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Features/Sources/Features/Forms/ApplicationFormView.swift`
> 【計画】`/Users/yuyamorishita/オタ活アプリ/docs/plans/event-name-suggestion/plan.md` §4 T2 / D-3 / D-5、
> 受入基準は `requirements.md` §6 の AC-ES-06〜13-M。
> 【やること】
> 1. `private var filteredEventNames: [String] { InputSuggestion.match(applicationStore.existingEventNames, query: eventName) }`
>    を既存 `filteredTours` / `filteredArtistNames` / `filteredVenueNames`（`:239-249` 付近）の並びに追加
> 2. `FormRow("公演名")`（`:57-64`）に `FormSuggestionList(items: filteredEventNames) { ... }` を追加する。
>    配置はツアー名行と同じ並び（`FormTextField` → 既存の FR-AE-7 ヒント → `FormSuggestionList`）
> 3. タップ時は `eventName = name` に加えて `applyEventAutofill(for: name)` を呼ぶ。この関数は
>    `applicationStore.eventAutofill(forEventNamed:)` の結果を使い、**対象の欄が trim して空のときだけ**
>    `tourName` / `artistName` / `venueName` に代入する。**`eventOn`（公演日）は絶対に触らない**
> 【従う既存例】`ApplicationFormView.swift:69-74`（ツアー名候補タップ + `if let` オートフィル）、
> `:87`（会場欄の `FormSuggestionList`）
> 【制約・やらないこと】`ApplicationStore` / `Domain` / `DesignSystem` / `DataStore` / `Networking` /
> `apps/api` は変更しない（T1 で確定済み）。`FormSuggestionList` の代わりに独自の候補行を書かない。
> マッチ規則を View にコピーしない（`localizedCaseInsensitiveContains` を書かない）。
> 非空の欄を上書きしない。モード（create / edit）で分岐しない
> 【完了条件】`xcodebuild -project /Users/yuyamorishita/オタ活アプリ/meigicho/Meigicho.xcodeproj -scheme Meigicho
> -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build`
> が BUILD SUCCEEDED + `plan.md` §5.2 の AC-ES-06〜13-M をシミュレータで実施
> 【報告】日本語で ①変更（file:line）②ビルド結果 ③AC-ES ごとの手動確認結果（未実施なら理由）④残課題

### T3 → docs 更新（planner か developer のどちらでも可）

> 【対象】`/Users/yuyamorishita/オタ活アプリ/docs/`
> 【やること】
> 1. `docs/01-product-overview.md:186` の Note「ツアー名・アーティスト名・会場名は既存候補をサジェスト」に
>    **公演名**を追加する
> 2. `docs/05-ios-client.md` のサジェスト記述（候補行 44pt / 部分一致）に公演名を含める。公演名だけ
>    並び順が「公演日の新しい順」であることを 1 行で明記する
> 3. `docs/09-roadmap.md` の Phase 0 に `0-11e`（公演名サジェスト・**0.5**・`docs/plans/event-name-suggestion/`）を
>    0-11d（`:85`）の直後に追加し、Phase 0 合計（`:94`）を補正する。※合計は 0-11c/0-11d 追加分の
>    既存 drift も残っている（`docs/plans/input-history-suggestions/review.md` 軽微 2）。まとめて直す場合は
>    どの行を足し込んだか差分の根拠を書くこと
> 4. `docs/plans/STATUS.md` に本計画を 1 行追記する
> 【やらないこと】`docs/09:163`（3-3 公演情報マスタ・Phase 3）は別物なので統合しない。BE / API の docs は触らない
> 【報告】日本語で ①変更（file:line）②スコープ外にした記述

### レビュー

実装完了後、**別セッション**で `code-reviewer`（model: sonnet で可 — iOS 単層・契約変更なし）を呼ぶ。
差分範囲は本ブランチ全差分、結果は `docs/plans/event-name-suggestion/review.md` へ。
観点: IOS-1 / IOS-5、マッチ規則のコピペ有無（R-2）、オートフィルが非空欄を上書きしないか（R-3）、
既存 4 フィールドの候補（昇順）に回帰が無いか、`apps/api` / `DataStore` への波及ゼロ、docs との整合。
スコープ外（BE 変更・公演の名前ベース find-or-create・R2-8 重複検知の修正・他 4 フィールドの並び順変更）は
指摘対象にしない。
