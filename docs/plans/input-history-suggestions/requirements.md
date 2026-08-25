# input-history-suggestions — Requirements

申込フォームの**アーティスト名**と**会場名**を、自分の過去入力履歴から選んで入力できるようにする。
仮回答は `questions-requirements.md`（Q1〜Q8）。本書はその仮回答を前提に確定させたもの。

---

## 1. 現状把握（ギャップ分析）

| 対象 | 現状 | 出典 |
|---|---|---|
| ツアー名 | **サジェスト実装済み**。部分一致・大小無視・完全一致は除外・上限なし | `ApplicationFormView.swift:66-81`, `:243-249` |
| ツアー名の候補ソース | `ApplicationStore.existingTourNames`（`Array(Set(tours.map(\.name))).sorted()`） | `ApplicationStore.swift:305-307` |
| アーティスト名 | 素の `FormTextField`。サジェストなし | `ApplicationFormView.swift:82-89` |
| 会場名 | 素の `FormTextField`。サジェストなし | `ApplicationFormView.swift:90-92` |
| 候補の元データ | `ApplicationStore.tours` / `.events`。起動時 `applicationStore.load()` → `loadCatalog()` で全件ロード済み | `MeigichoApp.swift:122,198`, `ApplicationStore.swift:55-69` |
| ローカル取得 | `SwiftDataCatalogRepository.listTours/listEvents` は `deletedAt == nil` の**全件**（ページングなし） | `SwiftDataCatalogRepository.swift:18-33` |
| BE 取得 | `GET /v1/tours` / `GET /v1/events` も**全件**（`ownerId` + `deletedAt: null`、ページングなし） | `apps/api/src/events/events.service.ts:41-48` |
| docs の記述 | 「ツアー名は既存候補をサジェスト」「候補行（各44pt）」。ただし docs は**前方一致**、実装は**部分一致**でズレている | `docs/01:186`, `docs/05:482-484` |
| ロードマップ | 0-11 に「既存ツアーのサジェスト付き」。**アーティスト・会場のサジェストは未記載**。3-3（Phase 3）は全ユーザー横断マスタで別物 | `docs/09:82`, `docs/09:161` |
| 死にコード | `@State private var showTourSuggestions` は一度も読まれていない（レビュー指摘済み・未修正） | `ApplicationFormView.swift:46`, `docs/plans/application-edit/review.md:50` |

**結論**: 必要なのは既存パターンの横展開のみ。**DB 変更ゼロ・BE 変更ゼロ・API 契約変更ゼロ**。

### 1.1 前提となる既存挙動（重要）

作成時に**既存ツアー名と同名**で保存すると、ローカルの find-or-create は既存ツアーを再利用し、
入力されたアーティスト名を**反映しない**（`SwiftDataApplicationRepository.swift:247` の
`existing.id == draft.id` が偽になる。作成時の `TourDraft.id` は常に新規 UUID —
`Drafts.swift:62`）。BE 側は逆に送信値を優先する（`tours.service.ts:131`）が、本番の iOS は
ローカル SSoT + `POST /v1/sync/push` 経路なのでローカルの挙動が実効仕様。

→ FR-6（ツアー候補選択時のアーティスト名オートフィル）はこの不一致を**画面上で解消する**ためのもの。
既存挙動そのものの修正は対象外（Q6-A）。

---

## 2. 機能要件

| ID | 要件 | 根拠 |
|---|---|---|
| FR-1 | 申込フォームの**アーティスト / グループ**欄で、1 文字以上入力すると過去のアーティスト名候補を表示し、タップで確定できる | Q1-A |
| FR-2 | 申込フォームの**会場**欄で、1 文字以上入力すると過去の会場名候補を表示し、タップで確定できる | Q1-A |
| FR-3 | アーティスト名候補は自分の全ツアーの `artistNameRaw` から重複除去して作る。会場名候補は自分の全公演の `venueNameRaw` から重複除去して作る。**空文字・空白のみは候補に含めない**（両フィールドとも Domain 上は非 Optional `String` で、BE の null が `""` に落ちるため） | `Models.swift:98,114` |
| FR-4 | 会場名候補は**ツアー / アーティストで絞り込まない**（全履歴）。同じツアーの次の公演は別会場であるのが通常で、絞ると候補が出ない | Q2 討議 |
| FR-5 | マッチ規則はツアー名の既存挙動と同一: 部分一致 / 大小無視 / クエリと完全一致（大小無視）の候補は除外 / クエリが空・空白のみなら候補ゼロ | `ApplicationFormView.swift:243-249` |
| FR-6 | ツアー名候補をタップしたとき、そのツアーの `artistNameRaw` が非空ならアーティスト欄へ自動反映する（空なら何もしない＝ユーザー入力を消さない） | Q5-A・§1.1 |
| FR-7 | 候補は**最大 5 件**。ツアー名サジェストも同じ上限に揃える | Q3-A |
| FR-8 | サジェストは**作成モード・編集モードの両方**で動作する（同一 View・同一入力欄なので分岐しない） | 既存のツアー名サジェストが両モードで出ている |
| FR-9 | 候補行のタップ領域は **44pt 以上**。既存のツアー名候補行（`.padding(.vertical, 8)` のみ）も揃える | `docs/05:483`, `docs/09:88`(0-16) |
| FR-10 | 候補はネットワークに依存しない（ローカルの `tours` / `events` から作る）。オフラインでも出る | `docs/00:116` ローカルファースト |
| FR-11 | 履歴ゼロ（初回ユーザー）のときは候補領域を出さない（空の枠を作らない） | 既存踏襲 |
| FR-12 | 公演名（イベント名）欄は**対象外** | Q2-A |
| FR-13 | 会員情報フォームの**FC名**欄（`MembershipFormView.swift:65`）でも、1文字以上入力すると過去のFC名候補を表示し、タップで確定できる。候補ソースは自分の全 `Membership.fanClubNameRaw` から重複除去（`IdentityStore.existingFanClubNames`）。マッチ規則・上限5件・44ptタップ領域はFR-5/7/9と同一 | Q7-B |

## 3. 非機能要件

| ID | 要件 |
|---|---|
| NFR-1 | マッチ規則は Domain の純粋関数に一本化し、3 フィールドで規則が分岐しないこと（View 側に規則をコピーしない） |
| NFR-2 | NFR-1 の関数と候補ソースは `swift test --package-path meigicho/Packages/Domain` で検証できること |
| NFR-3 | 候補計算は 1 キーストロークあたり O(候補総数)。数千件規模の履歴で体感遅延がないこと（Set 構築 + filter のみ。インデックス構造は作らない） |
| NFR-4 | `Features` から `DataStore` / `Networking` を参照しない（IOS-5）。View が触るのは `ApplicationStore` まで |
| NFR-5 | 候補行の色・寸法は `DesignSystem` 経由（View にマジック値を書かない） |

## 4. 制約・スコープ外

- **BE / Prisma / API 契約は変更しない**。追加エンドポイントも作らない
- 全ユーザー横断の公演情報マスタ（`docs/09:161` の 3-3・Phase 3）は作らない。候補は**自分の履歴のみ**
- 公演名サジェスト（Q2-A）は別起票
- FC名サジェスト（Q7-B・roadmap 0-7 の未実装分）は本計画に統合済み（FR-13）
- 「既存ツアーに吸収されるとアーティスト名入力が捨てられる」既存挙動の修正（Q6-A）
- 表記ゆれの正規化（全角/半角・スペース除去）、頻度順ソート、最近使った順ソートは行わない
- ツアー編集シート（`TourFormView`、`docs/plans/tour-edit-and-delete/` で新規作成予定）へのアーティスト名サジェスト追加は**当該計画の実装後のフォローアップ**

## 5. エッジケース

| # | ケース | 期待 |
|---|---|---|
| E-1 | 履歴ゼロ | 候補を出さない（FR-11） |
| E-2 | `artistNameRaw` / `venueNameRaw` が `""`（BE の null 由来） | 候補に含めない（FR-3）。空ボタンが並ばない |
| E-3 | 同名候補が複数ツアー / 複数公演に存在 | 重複除去して 1 行（FR-3） |
| E-4 | 論理削除済みツアー / 公演 | 候補に出ない（`listTours/listEvents` が `deletedAt == nil` で除外済み。追加実装不要） |
| E-5 | 大小違いのみの入力（`stellaris` に対し候補 `STELLARIS`） | 候補として表示される（完全一致除外は大小無視で判定するため**表示されない**）→ FR-5 のとおり除外。表記ゆれ吸収はしない |
| E-6 | オフライン / 未ログイン | ローカル履歴から候補が出る（FR-10） |
| E-7 | カタログ読み込み失敗（`catalogState == .failed`） | 直前まで読めていた `tours` / `events` は消えない（`ApplicationStore.loadCatalog:66-68`）ので候補は出続ける |
| E-8 | 候補が 5 件超 | 先頭 5 件（昇順の先頭）のみ（FR-7） |
| E-9 | 編集モードで初期値がそのまま入っている | クエリ＝現在値は完全一致なので候補ゼロ（画面を開いた瞬間に候補が出ない）— FR-5 の副次効果として正しい |
| E-10 | ツアー候補タップ後にユーザーがアーティスト名を手で書き換える | 書き換えは可能。ただし既存ツアー再利用時は保存に反映されない（§1.1・スコープ外） |

## 6. 受入基準

`T` = Domain XCTest で自動検証 / `M` = 手動確認（iOS）。

| AC-ID | 基準 | 種別 | 対応 FR |
|---|---|---|---|
| AC-SG-01-T | `existingArtistNames` は全ツアーの `artistNameRaw` を重複除去・空白のみ除外・昇順で返す | T | FR-3 |
| AC-SG-02-T | `existingVenueNames` は全公演の `venueNameRaw` を重複除去・空白のみ除外・昇順で返す | T | FR-3 |
| AC-SG-03-T | マッチ関数は部分一致・大小無視で候補を返す | T | FR-5 |
| AC-SG-04-T | クエリと完全一致（大小無視）する候補は返さない | T | FR-5 |
| AC-SG-05-T | クエリが空 / 空白のみなら空配列 | T | FR-5 |
| AC-SG-06-T | 候補が 6 件以上ヒットしても返るのは 5 件 | T | FR-7 |
| AC-SG-07-T | `artistName(forTourNamed:)` は名前が完全一致するツアーの非空 `artistNameRaw` を返す。一致なし / 空なら nil | T | FR-6 |
| AC-SG-08-T | `existingTourNames` + マッチ関数の組み合わせが、既存 `filteredTours` と同じ結果を返す（上限 5 件を除き回帰なし） | T | FR-7 |
| AC-SG-09-M | 申込追加でアーティスト欄に 1 文字入力 → 過去のアーティスト名候補が出る。タップで欄が確定する | M | FR-1 |
| AC-SG-10-M | 申込追加で会場欄に 1 文字入力 → 過去の会場名候補が出る。タップで欄が確定する | M | FR-2 |
| AC-SG-11-M | ツアー名候補をタップすると、そのツアーのアーティスト名がアーティスト欄に入る（空のツアーなら欄は変わらない） | M | FR-6 |
| AC-SG-12-M | 申込 0 件の状態ではどの欄でも候補が出ない | M | FR-11 |
| AC-SG-13-M | 申込詳細 → 編集で開いたフォームでも同じ候補が出る | M | FR-8 |
| AC-SG-14-M | 機内モードでも候補が出る | M | FR-10 |
| AC-SG-15-M | 候補行のタップ領域が 44pt 以上で、行の端をタップしても選択できる | M | FR-9 |
| AC-SG-16-M | 候補が多い状態でもフォームが極端に押し下がらない（5 件まで） | M | FR-7 |
| AC-SG-17-T | `existingFanClubNames` は全会員情報の `fanClubNameRaw` を重複除去・空白のみ除外・昇順で返す | T | FR-13 |
| AC-SG-18-M | 会員情報フォームのFC名欄に1文字入力 → 過去のFC名候補が出る。タップで欄が確定する | M | FR-13 |
