# event-name-suggestion — Requirements

申込フォームの**公演名**欄を、自分の過去入力履歴から選んで入力できるようにする。
`input-history-suggestions`（roadmap 0-11d）で対象外にした FR-12「公演名は別起票」の**別起票分**。
仮回答は `questions-requirements.md`（Q1〜Q5）。本書はその仮回答を前提に確定させたもの。

---

## 1. 現状把握（ギャップ分析）

**前提訂正**: 起票時に「`input-history-suggestions` は未実装」とされていたが誤り。
**すでに main にマージ済み**（`c1658d1 Merge pull request #19 from yumori59/feat/input-history-suggestions`）。
`tour-edit-and-delete`（#17）・`membership-full-number`（#18）も同様。詳細は `questions-requirements.md` 冒頭。

| 対象 | 現状 | 出典 |
|---|---|---|
| 共有マッチ規則 | `InputSuggestion.candidates(from:)`（trim→空除去→重複除去→**昇順**）/ `match(_:query:limit:)`（部分一致・大小無視・完全一致除外・上限 5）が**実装済み** | `Domain/Models/InputSuggestion.swift:12-27` |
| 共有 UI 部品 | `FormSuggestionList(items:onSelect:)`（`minHeight: 44`・空なら非描画）が**実装済み** | `DesignSystem/Components/FormComponents.swift:96-123` |
| ツアー名 | サジェスト配線済み + タップでアーティスト名オートフィル | `ApplicationFormView.swift:69-74` |
| アーティスト名 / 会場 | サジェスト配線済み | `ApplicationFormView.swift:78, 87` |
| FC名 | サジェスト配線済み | `MembershipFormView.swift:73` |
| **公演名** | **素の `FormTextField`。サジェストなし**（唯一の未対応フィールド） | `ApplicationFormView.swift:57-64` |
| 候補の元データ | `ApplicationStore.events`（`EventEntity`: `tourID` / `name` / `venueNameRaw` / `eventDate` / `updatedAt` を持つ）。起動時 `load()` → `loadCatalog()` で全件ロード済み | `Models.swift:110-138`, `ApplicationStore.swift:50-69` |
| 候補ソースの置き場 | `ApplicationStore` の computed（`existingTourNames` / `existingArtistNames` / `existingVenueNames`） | `ApplicationStore.swift:305-317` |
| オートフィルの前例 | `artistName(forTourNamed:)`（完全一致・非空のときだけ返す） | `ApplicationStore.swift:319-324` |
| Domain テスト | `InputSuggestionTests.swift` が稼働（`swift test` で 287 件緑） | `docs/plans/input-history-suggestions/review.md` |

**結論**: 必要なのは既存部品への 5 フィールド目の接続 + 公演名固有の並び順。
**DB 変更ゼロ・BE 変更ゼロ・API 契約変更ゼロ**。

### 1.1 公演エンティティは名前で再利用されない（重要）

- 作成経路の `EventDraft` は毎回新規 UUID（`Drafts.swift:77`）
- ローカル `upsertEvent` は `draft.id` でしか既存を探さない（`SwiftDataApplicationRepository.swift:271`）。
  ツアーの `findOrCreateTour`（名前ベース・`:219`）に相当する仕組みは**公演には無い**
- BE も id 基準（`apps/api/src/applications/use-cases/create-application.use-case.ts:41-42`）

→ 公演名サジェストは**テキスト入力の補助であって、同じ公演への紐づけではない**（Q2-A）。
その帰結として、同じ公演名で 2 件申し込んでも `event_id` が別なので `docs/01` R2-8 の重複検知
（`DuplicateApplicationDetection.swift:5-11` は `eventID` 基準）は発火しない。
**これは本計画以前からの既存挙動**で、本計画では直さない（§4 スコープ外）。

### 1.2 辞書順 + 上限 5 件は公演名では破綻する

公演名は「ツアー名 + 都市」で共通接頭辞が長い（プレースホルダ `例）STELLARIS ARENA TOUR 2026 -福岡公演-`）。
`candidates(from:)` は `sorted()` 昇順（`InputSuggestion.swift:15`）、`match` は先頭 `prefix(limit)`
（`:26`）なので、ツアー名部分を打った瞬間に**古い年のツアーの公演名が 5 枠を占有**し、
いま入力したい最新ツアーの候補が 1 件も出ない。他 4 フィールド（ツアー名・アーティスト・会場・FC名）は
共通接頭辞が短く、この問題が顕在化しない。→ FR-ES-4。

---

## 2. 機能要件

| ID | 要件 | 根拠 |
|---|---|---|
| FR-ES-1 | 申込フォームの**公演名**欄で、1 文字以上入力すると過去の公演名候補を表示し、タップで欄を確定できる | 要望・Q3-A |
| FR-ES-2 | 候補ソースは自分の**全公演**（`ApplicationStore.events`）の `name`。ツアー / アーティストで**絞り込まない**。空文字・空白のみは含めない | Q1-A |
| FR-ES-3 | マッチ規則・上限（5 件）・表示条件は既存 4 フィールドと**同一**（`InputSuggestion.match` をそのまま使う。規則を複製しない） | Q3-A・NFR-1 |
| FR-ES-4 | 公演名候補の**並び順は「公演日の新しい順」**（`eventDate` 降順、`nil` は最後、同日は `updatedAt` 降順）。重複名は最初に現れたもの（＝最も新しい公演）だけを残す。他 4 フィールドの昇順は変えない | §1.2・Q1-A |
| FR-ES-5 | 公演名候補をタップしたとき、**空の欄だけ**その公演の値で補完する: ツアー名 ← 公演が属するツアーの `name` / アーティスト ← そのツアーの `artistNameRaw` / 会場 ← その公演の `venueNameRaw`。補完元の値が空なら何もしない。**公演日は補完しない** | Q4-B |
| FR-ES-6 | FR-ES-5 の補完元は、同名の公演が複数あるとき FR-ES-4 の並びで**最も新しい 1 件** | 一意に決める必要があるため |
| FR-ES-7 | サジェストは**作成モード・編集モードの両方**で動作する（同一 View・分岐しない） | 既存 4 フィールドと同じ（FR-8 相当） |
| FR-ES-8 | 候補はネットワークに依存しない（ローカルの `events` / `tours` から作る）。オフラインでも出る | `docs/00:116` ローカルファースト |
| FR-ES-9 | 履歴ゼロのときは候補領域を出さない（`FormSuggestionList` が空配列で非描画） | 既存踏襲 |
| FR-ES-10 | 公演名候補の選択は「同じ公演に紐づける」ことを意味しない。UI 文言でそう読める表現を出さない | §1.1・Q2-A |

## 3. 非機能要件

| ID | 要件 |
|---|---|
| NFR-1 | マッチ規則は `InputSuggestion.match` の**1 実装のみ**。View に `localizedCaseInsensitiveContains` 等の規則をコピーしない（5 フィールド目でも同じ） |
| NFR-2 | 候補ソース（`existingEventNames`）とオートフィル解決は Domain 側に置き、`swift test --package-path meigicho/Packages/Domain` で検証できること |
| NFR-3 | 候補計算は 1 キーストロークあたり O(公演数 log 公演数)（ソート込み）。数千件でも体感遅延がないこと。インデックス構造やキャッシュは作らない（`@Observable` の computed で毎回計算する既存方針を踏襲） |
| NFR-4 | `Features` から `DataStore` / `Networking` を参照しない（IOS-5）。View が触るのは `ApplicationStore` と `DesignSystem` まで |
| NFR-5 | 候補行の見た目・寸法は既存 `FormSuggestionList` をそのまま使う（新しい行 View を作らない） |

## 4. 制約・スコープ外

- **BE / Prisma / API 契約は変更しない**。候補取得エンドポイントも作らない（§1 の根拠表）
- 公演エンティティの名前ベース find-or-create（同じ公演への紐づけ）は作らない（Q2-A・§1.1）
- R2-8 重複申込検知が作成経路で発火しない既存問題は直さない（§1.1）。別起票候補
- 全ユーザー横断の公演情報マスタ（`docs/09:163` の 3-3・Phase 3）は作らない
- 公演日のオートフィル（Q4 の議論参照）
- 他 4 フィールドの並び順を「最近使った順」に変えること（公演名のみ FR-ES-4 を適用。統一するかは
  フォローアップで判断する）
- 表記ゆれの正規化（全角/半角・スペース除去）、頻度順ソート
- `TourFormView`（`tour-edit-and-delete` で実装済み）への公演名サジェスト追加（公演名欄が無いので対象外）

## 5. エッジケース

| # | ケース | 期待 |
|---|---|---|
| E-1 | 公演履歴ゼロ | 候補を出さない（FR-ES-9） |
| E-2 | `name` が空文字・空白のみの公演 | 候補に含めない（FR-ES-2。`candidates` 側で除去） |
| E-3 | 同名の公演が複数（＝同じ公演名で複数回申し込んだ結果） | 候補は 1 行。補完元は最も新しい 1 件（FR-ES-6） |
| E-4 | `eventDate` が `nil` の公演（`Models.swift:115-116` で null あり） | 候補には出る。並びは日付ありより**後ろ**（FR-ES-4） |
| E-5 | 論理削除済みの公演 / ツアー | 候補に出ない（`listEvents` / `listTours` が `deletedAt == nil` で除外済み。追加実装不要） |
| E-6 | 候補の公演が属するツアーが `tours` に無い（未ロード・削除済み） | ツアー名・アーティストは補完しない（会場だけ補完する）。クラッシュ・空文字代入をしない |
| E-7 | 編集モードで初期値のまま開いた | クエリ＝現在値は完全一致なので候補ゼロ（FR-ES-3 の副次効果） |
| E-8 | 編集モードで会場欄が空のまま公演名候補をタップ | 会場が補完される＝公演の内容変更なので、既存の波及ヒント（`ApplicationFormView.swift:59-63`）が自動で出る／件数が更新される。黙って波及しないことを手動確認する（AC-ES-10-M） |
| E-9 | 作成モードでツアー名を先に入力してから公演名候補をタップ | ツアー名は**上書きしない**（空でないため。FR-ES-5） |
| E-10 | オフライン / 同期失敗（`catalogState == .failed`） | 直前まで読めていた `events` は消えない（`ApplicationStore.loadCatalog:60-67`）ので候補は出続ける（FR-ES-8） |
| E-11 | 候補が 5 件超 | FR-ES-4 の並びの先頭 5 件（新しい順） |
| E-12 | 同じ公演名を選んだのに別の `event_id` が作られる | 仕様どおり（§1.1）。UI で「同じ公演」と表現しない（FR-ES-10） |

## 6. 受入基準

`T` = Domain XCTest で自動検証 / `M` = 手動確認（iOS）。

| AC-ID | 基準 | 種別 | 対応 FR |
|---|---|---|---|
| AC-ES-01-T | `InputSuggestion.candidates(fromOrdered:)` は trim・空除去・重複除去（先勝ち）を行い、**入力順を保持**する（昇順ソートしない） | T | FR-ES-4 |
| AC-ES-02-T | `existingEventNames` は公演日の新しい順で返る。`eventDate == nil` の公演は末尾 | T | FR-ES-2/4 |
| AC-ES-03-T | 同名の公演が複数あっても `existingEventNames` は 1 件だけ返す | T | FR-ES-2・E-3 |
| AC-ES-04-T | `eventAutofill(forEventNamed:)` は名前が完全一致する最新の公演から ツアー名 / アーティスト名 / 会場 を返す。それぞれ空文字なら `nil`。一致なしなら戻り値自体が `nil`。ツアーが解決できないときはツアー名・アーティストが `nil` で会場のみ返る | T | FR-ES-5/6・E-6 |
| AC-ES-05-T | `existingEventNames` + `InputSuggestion.match` の組み合わせが部分一致・大小無視・完全一致除外・上限 5 件で動く（既存規則の再利用であることの回帰） | T | FR-ES-3 |
| AC-ES-06-M | 申込追加で公演名欄に既存公演名の一部を入力 → 候補が出る。タップで欄が埋まり、タップ後は完全一致で候補が消える | M | FR-ES-1 |
| AC-ES-07-M | 同じツアーの公演を複数持つ状態でツアー名部分を入力 → **新しいツアーの公演が候補に出る**（古いツアーで 5 枠が埋まらない） | M | FR-ES-4 |
| AC-ES-08-M | 作成モードで空欄のまま公演名候補をタップ → ツアー名・アーティスト・会場が埋まる。公演日は today のまま変わらない | M | FR-ES-5 |
| AC-ES-09-M | 作成モードでツアー名だけ先に手入力してから公演名候補をタップ → ツアー名は書き換わらず、アーティスト・会場だけ埋まる | M | FR-ES-5・E-9 |
| AC-ES-10-M | 編集モード（他に同じ公演を参照する申込がある申込）で公演名候補をタップ → 波及ヒントが表示され、既に値のある欄は書き換わらない | M | FR-ES-7・E-8 |
| AC-ES-11-M | 申込 0 件の状態で公演名欄に入力 → 候補も空の枠も出ない | M | FR-ES-9 |
| AC-ES-12-M | 機内モードで AC-ES-06-M を再実行 → 候補が出る | M | FR-ES-8 |
| AC-ES-13-M | 候補行の右端（文字の無い余白）をタップ → 選択される（既存 `FormSuggestionList` の回帰） | M | NFR-5 |
