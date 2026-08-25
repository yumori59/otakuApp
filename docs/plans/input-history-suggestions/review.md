# input-history-suggestions レビュー結果

対象: `feat/input-history-suggestions` の working tree 全差分（`git diff` 未コミット + 新規ファイル）。
第三者レビュー（実装エージェントと別セッション）。

## レビュー結果サマリ
- 重大: 0 件
- 中: 0 件
- 軽微/提案: 2 件

## 重大 (Must Fix)
なし。

## 中 (Should Fix)
なし。

## 軽微 (Nice to Have)

1. **シミュレータでの手動確認（AC-SG-09〜16-M, AC-SG-18-M）が未実施** — plan.md §5.2 に定義済みの手動確認手順が、実装エージェントの報告どおり未実施のまま。特に AC-SG-11-M（ツアー候補タップ時のアーティスト欄オートフィル）と AC-SG-15-M（候補行の右端タップでも選択できるか＝`FormSuggestionList` の `Button` ラベル全体がタップ領域になっているか）はコードレビューだけでは実機での見た目・挙動を保証しきれない。マージ前提条件にはしないが、マージ後早めに実施することを推奨。
2. `docs/09-roadmap.md` の Phase 0 合計工数（57.5人日）が今回の 0-11c 追加分（0.5人日）を反映していない — 事前情報のとおり今回のスコープ外の既存drift（複数タスク追加時からの累積ズレ）であり、本実装による新規の問題ではない。指摘のみ。ついでに直す価値はあるが本PRの必須事項ではない。

## 良かった点

- **規則の一本化（D-1）が徹底されている**: `InputSuggestion.candidates(from:)` / `InputSuggestion.match(_:query:limit:)` が唯一のマッチ規則実装。`grep -rn "localizedCaseInsensitiveContains"` で Features 配下に規則コピーが残っていないことを確認済み（`ApplicationStore.swift:264` の類似コードは検索機能の既存実装で無関係）。旧 `filteredTours` の直書き規則（3項目バラバラになるリスク＝R-1）を確実に潰している。
- **候補ソースの配置（D-2）が正しい**: `existingArtistNames` / `existingVenueNames` は `ApplicationStore`、`existingFanClubNames` は `IdentityStore` に、それぞれ `@Observable` の computed property として実装されており、キャッシュせず毎回再計算する設計（`ApplicationStore.swift:306-320`, `IdentityStore.swift:91-95`）。同期 pull 後の陳腐化を避ける設計判断（D-2 却下理由）どおり。
- **オートフィルが安全（D-3・FR-6）**: `artistName(forTourNamed:)` は完全一致 + 非空のときのみ値を返し（`ApplicationStore.swift:315-319`）、View 側も `if let artist = ...` で非 nil のときだけ上書き（`ApplicationFormView.swift:69-74`）。ユーザー入力を空文字で消す事故が起きない設計になっている。テスト（`AC-SG-07-T`）でも空アーティストのツアーは `nil` を返すことを確認済み。
- **共有 View（D-4）が徹底利用されている**: `FormSuggestionList`（`FormComponents.swift:96-121`）が `minHeight: 44` を確保し、ツアー名・アーティスト名・会場名・FC名の4箇所全てで同一コンポーネントを使用（grep で重複実装なしを確認）。DesignSystem 側は `InputSuggestion` を知らず `[String]` を受け取るだけの疎結合で、レイヤ違反もない。
- **アーキテクチャ違反なし**: `Features` から `DataStore` / `Networking` の import なし（IOS-5）。`Domain` に `SwiftData` の import なし。BE / Prisma / `Packages/Networking` は 1 行も変更されていない（`git status` で確認、`apps/api/` 配下に差分なし）。
- **死にコード削除（D-8）確認**: `showTourSuggestions` は宣言・参照ともに完全に削除済み（grep で0件）。削除に伴う振る舞い変更もなし（元々一度も読まれていなかった変数）。
- **T5（FC名）が T3 と同じパターンで実装されている**: `IdentityStore.existingFanClubNames` は `ApplicationStore.existingArtistNames` と同型（`InputSuggestion.candidates(from:)` に委譲するだけ）、`MembershipFormView` の配線も `ApplicationFormView` と同じ `InputSuggestion.match` + `FormSuggestionList` の形。テスト（`IdentityStoreSuggestionTests.swift`）も `InputSuggestionTests.swift` の `existingArtistNames` テストと同じ観点（重複除去・trim・空除外・昇順）を踏襲しており、平仄のズレなし。
- **テスト実測で green を確認**: `swift test --package-path meigicho/Packages/Domain` を実行し、287件全通過（既存回帰含む）を本レビューで再現確認済み。`xcodebuild ... build` も実行し `** BUILD SUCCEEDED **` を確認、かつ変更ファイル（`FormComponents.swift` / `ApplicationFormView.swift` / `MembershipFormView.swift` / `ApplicationStore.swift` / `IdentityStore.swift`）に関する新規warningなし。
- **docs 更新の正確性**: `docs/01-product-overview.md` / `docs/05-ios-client.md` / `docs/09-roadmap.md`（0-11c 追加・0-7 実装済み化）/ `docs/plans/STATUS.md` §14 の記述が実装内容と一致していることを確認。`docs/05` の「前方一致」→「部分一致」への訂正も実装（`localizedCaseInsensitiveContains`）と整合している。
- **リスク（R-1〜R-7）は全て手当て済み**: R-1（規則コピペ）grep 済み、R-2（空候補）trim+空除去テスト済み、R-3（`ApplicationStore.swift` の他計画との衝突）は今回 T1 のみが触っており未衝突、R-4（DataStore import）grep 済みでなし、R-5（既存配置踏襲）は `FormRow` 内・入力欄直下に統一、R-6（オートフィルはタップ時のみ発火）はハンドラ内に閉じている、R-7（BE 変更ゼロ）は `git status` で確認済み。

## 検証コマンドと結果（本レビューで実行）

```
swift test --package-path meigicho/Packages/Domain
→ Executed 287 tests, with 0 failures (0 unexpected)

xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath <scratchpad>/meigicho-build CODE_SIGNING_ALLOWED=NO build
→ ** BUILD SUCCEEDED **（変更ファイルに新規warningなし）

git status（apps/api 配下）
→ 差分なし。BE/Prisma/API契約への影響ゼロを確認
```

## 結論

重大・中とも 0 件。設計判断（D-1〜D-8）・タスク分解（T1〜T5）・リスク対策（R-1〜R-7）のすべてがコードに反映されており、plan.md / requirements.md との齟齬なし。**マージ可**。ただしシミュレータでの手動確認（AC-SG-09〜16-M, 18-M）はマージ後の早期実施を推奨。
