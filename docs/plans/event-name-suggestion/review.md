# event-name-suggestion — レビュー結果

対象差分: `meigicho/Packages/Domain/Sources/Domain/Models/InputSuggestion.swift` /
`meigicho/Packages/Domain/Sources/Domain/Stores/ApplicationStore.swift` /
`meigicho/Packages/Domain/Tests/DomainTests/InputSuggestionTests.swift` /
`meigicho/Packages/Features/Sources/Features/Forms/ApplicationFormView.swift`

検証ゲート:
- `swift test --package-path meigicho/Packages/Domain` → **309 件全緑**（既存 287 件 + 新規 22 件、失敗 0）
- `xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build` → **BUILD SUCCEEDED**

## レビュー結果サマリ
- 重大: 0 件
- 中: 0 件
- 軽微/提案: 2 件

## 重大 (Must Fix)
なし

## 中 (Should Fix)
なし

## 軽微 (Nice to Have)

1. [`meigicho/Packages/Domain/Tests/DomainTests/InputSuggestionTests.swift:117-133`]
   `test_existingEventNames_dedupesSameName_keepsOneEntry`（AC-ES-03-T）は「1 件だけ残る」ことしか
   検証しておらず、「残る 1 件が最も新しい公演か」までは踏み込んでいない（`.filter { $0 == "X 福岡公演" }.count == 1`）。
   実装（`eventsByRecency` 降順 → `candidates(fromOrdered:)` の先勝ち dedup）は正しく最新を残すため実害は
   ないが、FR-ES-4 の「重複名は最も新しい公演を残す」という要件の直接検証としては
   `test_eventAutofill_returnsTourArtistVenue_forMostRecentMatch`（AC-ES-04-T）に依存している状態。
   次回追記の余地があれば `existingEventNames` 側でも newest 側の値が残ることを直接アサートすると良い。

2. [`meigicho/project.yml` / `meigicho/Meigicho.xcodeproj/project.pbxproj`]
   `git status` 上は差分ありだが、内容は `API_BASE_URL`（Cloud Run URL）・`DEVELOPMENT_TEAM` /
   `CODE_SIGN_STYLE`・`Config/Debug.xcconfig` の追加など署名・環境設定であり、公演名サジェスト機能とは
   無関係と確認した（差分内容を確認済み）。本タスクの成果物ではないため指摘対象外とするが、
   コミット時に無関係な差分を一緒に含めないよう注意（別コミットに分離推奨）。

## 良かった点

- `InputSuggestion.candidates(fromOrdered:)` は既存 `candidates(from:)` / `match` のシグネチャ・挙動を
  変更せず追加のみ（`InputSuggestion.swift:18-30`）。既存 4 フィールドの昇順ロジックに回帰なし
  （`swift test` 309 件中、既存 287 件も全緑）。
- マッチ規則のコピペなし。`ApplicationFormView.swift` に `localizedCaseInsensitiveContains` 等の独自実装は
  見当たらず、`filteredEventNames`（`:255-257`）は既存 3 フィールドと同じく `InputSuggestion.match` を
  そのまま呼んでいる（NFR-1 遵守）。
- オートフィル（`applyEventAutofill`, `ApplicationFormView.swift:260-271`）は
  `tourName.trimmingCharacters(in: .whitespaces).isEmpty` 等、**trim して空のときだけ代入**するガードが
  3 項目すべてに一貫して入っており、`eventOn`（公演日）には一切触れていない（FR-ES-5・R-3 対応）。
  既存パターン（`.trimmingCharacters(in: .whitespaces)`）とも file:line 単位で一致（`:166, 289-300` 等）。
- 並び順の実体を `eventsByRecency`（private, `ApplicationStore.swift:326-343`）1 本に集約し、
  `existingEventNames` と `eventAutofill(forEventNamed:)` の両方がこれを参照する設計になっており、
  「同名の公演のうち最も新しい 1 件」の定義が 2 箇所でズレる余地がない（D-4 どおり）。
- `nil` 混在の日付比較（`eventDate: Date?` の降順・同値時は `updatedAt` 降順）は strict weak ordering を
  壊しておらず、`test_existingEventNames_ordersByEventDateDescending_nilLast` でクラッシュ・不定順なく
  緑。R-6 のリスクは解消済みと確認。
- `eventAutofill` の名前比較は両辺 `trimmingCharacters(in: .whitespacesAndNewlines)` で行っており、
  末尾空白付きの公演名でも一致する（R-7 対応、`test_eventAutofill_trimsBothSidesBeforeComparing` で検証済み）。
- ツアー未解決時（`E-6`）はクラッシュや空文字代入をせず、`tourName` / `artistNameRaw` を `nil` にして
  `venueNameRaw` のみ返す実装（`ApplicationStore.swift:349-356`）。テストも
  `test_eventAutofill_missingTour_returnsVenueOnly` で確認済み。
- `Features` の import は `SwiftUI` / `DesignSystem` / `Domain` / `Core` のみ。`DataStore` /
  `Networking` を直接参照していない（IOS-5 なし）。
- UI 配線は死んでおらず、`FormRow("公演名")` 内に `FormSuggestionList` が直接埋め込まれ、タップで
  `eventName` 代入 + `applyEventAutofill` が呼ばれる（IOS-1 なし）。配置もツアー名行と同じ
  `TextField → Hint → FormSuggestionList` の並びで D-5 どおり。
- `apps/api` / Prisma / `Packages/Networking` / `Packages/DataStore` への差分はゼロ（`git diff --stat` で確認）。
  API 契約 3 層（Prisma / NestJS / iOS Domain・Network）に変更なし。

## 手動確認（AC-ES-06〜13-M）について
本レビューはビルド確認までを実施。シミュレータでの手動確認は別途実施予定（タスク指示どおりスコープ外）。
