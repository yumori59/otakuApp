# identity-grouping — Workflow Plan

`requirements.md` の受入基準を実装タスクへ分解する。着手前に `questions-requirements.md` の Q1〜Q7 の回答がデフォルト仮定と一致しているか確認すること。

## 0. 現状把握（ギャップ分析）

| 層 | 既にあるもの | 欠けているもの |
|---|---|---|
| DB | `identities` / `memberships`（`fan_club_name_raw` は自由入力文字列） | **変更なし**。グループ用の列もマスタ紐付けも作らない |
| BE | `GET /v1/identities`（`identities.service.ts:40-47`、`sortOrder` 昇順）/ `GET /v1/memberships` が全件フラットに返す | **変更なし**。集計エンドポイントも追加しない（D-1） |
| iOS Domain | `IdentityStore.memberships(for:)`（`:78-80`）、`fanClubNames(for:)`（`:87-89`）、`nearestRenewal(for:)`（`:83-85`）、`sortedIdentities(by:winCounts:)`（`:100-116`） | FC をキーにした束ね（`groupedByFanClub`）。FC 名の正規化関数。「そのFCの会員情報」を基準にした並べ替え |
| iOS Features | `IdentityListView.swift`（`ScrollView` + `SegmentedPicker` + `CardList` + `ForEach`、行は `identityRow(_:)` `:134-154`） | グループ見出しの描画。行が「名義×会員情報」になることへの追従 |
| iOS DesignSystem | `SectionHeader` / `CardList` / `ListRow`（`ListRow.swift:88-108`） | **変更なし**。既存コンポーネントの組み合わせで足りる |
| docs | `docs/05-ios-client.md:324`（S2 名義一覧）、`docs/09-roadmap.md:70`（0-4） | グルーピングの記述。ロードマップ行（0-4b） |

**結論**: BE・DB 変更ゼロ。不足は **iOS の `Domain` に束ねロジックを足し、`Features` の描画をそれに合わせる**ことだけ。

先例として `ApplicationStore.groupApplications(_:)`（`ApplicationStore.swift:309-324`）がツアー表で同じ形をしている。
本計画はそれを踏襲するが、**キーが UUID ではなく文字列**である点だけが違う（C-1 / D-3）。

## 1. 設計判断

### D-1 グルーピングは iOS のローカル計算で完結させる（BE 変更なし）

- iOS の書き込み・読み取りの SSoT はローカル SwiftData で、表示は `IdentityStore` が保持する配列から組み立てている（`IdentityStore.swift:37-53`、`AppEnvironment` が `SwiftData*Repository` を注入）。
- 却下 a: `GET /v1/identities?group_by=fan_club` を新設して BE でグループを組む。
  → 一覧が**オフラインで描けなくなる**（現状はローカルから描ける）。同期経路と REST 経路で表示が食い違う原因も作る。
- 却下 b: `GET /v1/identities` のレスポンスにグループ集計を追加する。
  → API 契約 3 層（Prisma ↔ NestJS ↔ iOS）を触る割に、iOS が既に持っているデータ（memberships 全件）の再送でしかない。
- 帰結: **`apps/api` と `schema.prisma` は 1 行も触らない**。BE の jest は本計画の完了ゲートに含めない。

### D-2 グループ内の行は `(Identity, Membership?)` のペアにする

FR-IG-2 で名義が複数グループに現れる以上、行の同一性は名義 ID だけでは決まらない（`ForEach` の `id` が重複する）。

- 採用: `FanClubGroup.Row { identity: Identity, membership: Membership? }`、`id` は `"\(identity.id)#\(membership?.id ?? "none")"`。
- これにより FR-IG-8 / FR-IG-9（そのFCの `renewalOn` を基準にする）が自然に書ける。
- 却下: 行を `Identity` のままにして、バッジ用の日付を別 Dictionary で持ち回る。
  → View 側で 2 つのコレクションを突き合わせることになり、`ForEach` の id 重複も残る。

### D-3 正規化キーは「幅・大小・空白」だけを畳む

`docs/03-database.md:417-425` は「文字列一致グルーピングはタイポで分裂する」として、ツアーでは `tour_id` への正規化を選んだ。FC は同じ正規化ができない（マスタが Phase 1 未実装 = C-1）ので、**畳みすぎない範囲で**分裂を減らす。

```swift
// Domain（純粋関数）
static func fanClubGroupKey(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines)
       .folding(options: [.widthInsensitive, .caseInsensitive], locale: nil)
       .replacingOccurrences(of: "[\\s\\u{3000}]+", with: " ", options: .regularExpression)
}
```

- `.diacriticInsensitive` と kana folding は**使わない**（AC-IG-05）。誤結合は利用者が自力で直せない。
- 表示名は原文を保持（FR-IG-4）。キーと表示を分けることで「勝手に表記を書き換えられた」を防ぐ。
- 却下: 正規化した文字列を `fanClubNameRaw` に書き戻して保存する。
  → 同期で他端末・BE に伝播する破壊的変更になる。`_raw` という列名の意図（`docs/03-database.md:341`「入力揺らぎ保持」）にも反する。

### D-4 グルーピングは常時オン。ソートは「グループ内の順序」に降格する

- 採用（Q4-A）: セグメンテッドコントロールは残し、意味を「グループ内の並び順」に変える。グループ自体の並びは FR-IG-6 で固定。
- 却下 a: ソートの 4 つ目に「FC別」を足す。→ ソートは 1 つしか選べないので、FC別を選んだ瞬間にグループ内の順序を決める手段が無くなる。
- 却下 b: 「一覧 / FC別」の表示モードトグルを足し、既定はフラット。→ 要望された機能が既定オフになり、誰も辿り着かない（IOS-1 の失敗形）。

### D-5 ロジックは `Domain` の純粋関数、View は描画だけ

`Packages/Domain` には稼働中の XCTest がある（`Domain/Tests/DomainTests/` 20 ファイル、`swift test --package-path` で実行 — `docs/plans/STATUS.md:135-137`）。
束ね・正規化・並べ替えは全て `IdentityStore` の**副作用の無いメソッド**に置き、AC-IG-01〜11 を Red→Green で通す。View 側に残すのは `SectionHeader` + `CardList` の組み立てだけ。

- 却下: `IdentityListView` の `signedInContent` 内で `Dictionary(grouping:)` する。→ AC-IG-01〜11 が全て手動確認になる。

## 2. API 契約

**変更なし。新規エンドポイントなし。**

本機能が依存する既存レスポンス（実装者はこれを正とする。**変更してはいけない**）:

| 経路 | 使うフィールド |
|---|---|
| `GET /v1/memberships` | `id` / `identity_id` / `fan_club_name_raw` / `renewal_on` / `rank` / `fee_yen`（`docs/04-api.md:214-226`） |
| `GET /v1/identities` | `id` / `display_name` / `color` / `joined_on`（`identities.service.ts:12-24`） |
| `POST /v1/sync/pull` | 上記 2 コレクション（`sync-serialize.ts:28-40`） |

DB スキーマ変更なし（`schema.prisma` は触らない）。

## 3. 実装タスク

### T1 (Domain) FC グルーピングの純粋ロジック — **テスト先行 (Red→Green)**

担当候補: `swift-developer`

**追加物**

`meigicho/Packages/Domain/Sources/Domain/Stores/IdentityStore.swift`（または `Domain/Grouping/FanClubGrouping.swift` として切り出し）:

```swift
public struct FanClubGroup: Identifiable, Equatable, Sendable {
    /// 正規化キー。FC未登録グループは "" 固定
    public let id: String
    /// 画面に出す名前。原文 or "FC未登録"
    public let displayName: String
    public let rows: [Row]
    /// グループ内の最小 renewalOn（並び順の基準。nil のみなら nil）
    public let nearestRenewalOn: Date?
    public var isUnregistered: Bool { id.isEmpty }

    public struct Row: Identifiable, Equatable, Sendable {
        public let identity: Identity
        public let membership: Membership?
        public var id: String { "\(identity.id.uuidString)#\(membership?.id.uuidString ?? "none")" }
    }
}

extension IdentityStore {
    public func groupedByFanClub(
        sortedBy order: IdentitySortOrder,
        winCounts: [UUID: Int]
    ) -> [FanClubGroup]
}
```

**振る舞い**

1. `memberships` を `fanClubGroupKey(fanClubNameRaw)` で束ねる（D-3）
2. 同一 (identity, key) が複数あれば `renewalOn` が近い方を採る。nil は最劣後（FR-IG-10）
3. 会員情報を 1 件も持たない `identity` を集めて `id: ""` / `displayName: "FC未登録"` のグループを作る（FR-IG-5）
4. グループ内を `order` で並べる。`.renewalSoon` の基準は **その行の `membership?.renewalOn`**（FR-IG-8）。`.mostWins` / `.joinedOldest` は既存 `sortedIdentities` と同じ基準
5. グループを `nearestRenewalOn` 昇順（nil は末尾）→ 同値は `displayName.localizedStandardCompare` で並べ、FC未登録を最後に付ける（FR-IG-6 / FR-IG-7）

**テスト**: `meigicho/Packages/Domain/Tests/DomainTests/FanClubGroupingTests.swift`（新規）

| AC-ID | テスト名の意図 |
|---|---|
| AC-IG-01 | 単一FCの名義が 1 グループ 1 行 |
| AC-IG-02 | 2FC所属の名義が 2 グループに現れ、行合計 = membership 件数 |
| AC-IG-03 | 会員情報なしの名義が "FC未登録" グループ、配列末尾 |
| AC-IG-04 | 全角・大小・前後空白・連続空白の違いが同一グループ / 表示名は最初の原文 |
| AC-IG-05 | 濁点違い・かなカナ違いは別グループ |
| AC-IG-06 | グループ順 = 最小 renewalOn 昇順 / nil 末尾寄せ / 同値は表示名順 |
| AC-IG-07 | FC未登録は基準に関わらず常に最後 |
| AC-IG-08 | `.renewalSoon` で同一名義の位置がグループごとに変わる（そのFCの日付が基準） |
| AC-IG-09 | `.mostWins` / `.joinedOldest` がグループ内で従来順 |
| AC-IG-10 | 同一名義×同一FCの重複会員情報が 1 行に畳まれ、近い方が採用される |
| AC-IG-11 | memberships が空なら FC未登録 1 グループのみ |

**完了条件**: `swift test --package-path meigicho/Packages/Domain` 全緑。

**やらないこと**: `IdentityStore` の既存メソッド（`sortedIdentities` / `nearestRenewal` / `fanClubNames`）のシグネチャ変更・削除。ホームや共有プレビューが使っている可能性があるため、新メソッドの追加に留める。

---

### T2 (Features) 名義一覧のグループ描画

担当候補: `swift-developer`（**T1 完了後**）

`meigicho/Packages/Features/Sources/Features/Identities/IdentityListView.swift`

1. `signedInContent`（`:96-128`）の `sorted` を `identityStore.groupedByFanClub(sortedBy:winCounts:)` に差し替える
2. `VStack(spacing: 20)` で `ForEach(groups)`。各グループは
   `SectionHeader("\(group.displayName)（\(group.rows.count)）")` + `CardList { ForEach(group.rows) { ... } }`
3. `identityRow(_:)`（`:134-154`）を `identityRow(_ row: FanClubGroup.Row)` に変更
   - `subtitle`: 会員情報のランク / 年会費（無ければ「会員情報なし」）。**FC 名連結はグループ見出しと重複するので出さない**（FR-IG-9 / Q5）
   - `trailing`: `row.membership?.renewalOn` の `CountdownBadge.renewal`。FC未登録グループは nil
   - `meta`: 現状維持（入会日・当選回数）
   - タップ遷移は `AppRoute.identity(row.identity.id)` のまま（FR-IG-12）
4. 広告は現状のまま **最下部 1 枚**（`PlacementAdSlot(placement: .identitiesBottom)`、`:124-126`）。グループ間には入れない（NFR-4）
5. 空状態・ゲート（`auth.isGuest`）・エラーバー・シート配線は変更しない

**制約**

- `List` へ書き換えない（NFR-5。`delete-ui` 計画と衝突する）
- `Features` から `DataStore` / `Networking` を参照しない（IOS-5）
- グループ数が多いときのために `CardList` の外側は `LazyVStack` を検討してよいが、`docs/05-ios-client.md:971` の方針（`LazyVStack`）に従うこと

**完了条件**: `xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build` が BUILD SUCCEEDED。

**手動確認手順**（AC-IG-12〜16）

| # | 操作 | 期待 |
|---|---|---|
| 1 | ログイン済みで名義タブを開く | FC 名の見出しごとに名義が束ねられている |
| 2 | 2 FC に所属する名義を用意して一覧を見る | 両方のグループに現れ、更新バッジがそれぞれのFCの日付になっている |
| 3 | 会員情報を持たない名義を作る | 「FC未登録」グループが一番下に出る |
| 4 | セグメントを「当選が多い順」に切り替える | グループは残ったまま、各グループ内の順序が変わる |
| 5 | 任意の行をタップ | 名義詳細が開く。どのグループから開いても同じ |
| 6 | 一覧を最下部までスクロール | 広告は最下部に 1 枚のみ。グループ間に無い |
| 7 | ログアウトして名義タブを開く | ログイン案内カードのみ（グループ見出しは出ない） |

---

### T3 (docs) 仕様への反映

担当候補: `swift-developer` または planner セッション（**T1 / T2 と並列可**）

| ファイル | 変更 |
|---|---|
| `docs/05-ios-client.md:324`（S2 の行）と `:371` 付近（ソートの記述） | 名義一覧が FC 別グルーピング表示であること、ソートは「グループ内の並び順」であることを追記 |
| `docs/01-product-overview.md` の要件表（R1 系） | 「名義をFC単位で束ねて俯瞰できる」を 1 行追加。ツアーの R2-4（`:71`）と同じ書式 |
| `docs/09-roadmap.md`（0-4 の直後 `:70`） | `0-4b 名義一覧のFC別グルーピング` を **1.0 人日** で追記。Phase 0 合計を更新（C-3 / Q7） |

**やらないこと**: `docs/03-database.md` / `docs/04-api.md` は変更しない（DB・API 契約に変更が無いため）。

---

## 4. 並列実行可能なタスク

| 並列グループ | タスク | 理由 |
|---|---|---|
| 並列 A | **T1**（Domain）と **T3**（docs） | 触るファイルが重ならない |
| 直列 | **T1 → T2** | T2 は `FanClubGroup` の型に依存する |

**同時に走らせてはいけないもの**

- `IdentityListView.swift` は `delete-ui` 計画（`docs/plans/delete-ui/`）が触る可能性がある。**着手前に `docs/plans/delete-ui/plan.md` の対象ファイルを確認**し、重なるなら直列化すること
- `docs/09-roadmap.md` は他計画も追記しうる。編集は 1 セッションずつ

## 5. 受入基準 → テストケース対応

| AC-ID | 種別 | 置き場所 |
|---|---|---|
| AC-IG-01 〜 AC-IG-11 | 自動 | `meigicho/Packages/Domain/Tests/DomainTests/FanClubGroupingTests.swift`（新規・Red 先行） |
| AC-IG-12 〜 AC-IG-16 | 手動 | T2 の手動確認手順 1〜7 |

BE のテスト（`apps/api`）は本計画では追加・変更しない（D-1）。

## 6. エッジケース

| # | ケース | 扱い |
|---|---|---|
| E-1 | 名義 0 件 | 従来の `EmptyStateView`。グループ見出しを出さない（FR-IG-11） |
| E-2 | 会員情報 0 件 | 「FC未登録」1 グループ（AC-IG-11） |
| E-3 | `fanClubNameRaw` が空文字 / 空白のみ | 正規化キーが `""` になり FC未登録グループと衝突する。**入力側で空文字は保存できない**（BE `@MinLength(1)`、`create-membership.dto.ts:32-34`）が、空白のみは通る。T1 で「正規化後が空ならFC未登録として扱う」を明示実装し、テストを 1 本足す |
| E-4 | 同一名義×同一FCの重複会員情報 | 1 行に畳む（FR-IG-10 / AC-IG-10） |
| E-5 | グループ数が多い（FCを数十件） | `LazyVStack` で描画。集計は毎フレーム走らないよう `signedInContent` 内で 1 回だけ呼ぶ（`docs/05-ios-client.md:979` の指摘と同じ注意） |
| E-6 | 同期で会員情報が後から届く | `IdentityStore.memberships` の変化で `@Observable` により再計算される。特別な対応不要 |
| E-7 | 削除済み（ソフトデリート）の会員情報 | `IdentityStore.memberships` はリポジトリが未削除のみを返す前提。**T1 の実装前に `SwiftDataMembershipRepository.list()` が `deletedAt == nil` で絞っているか確認**すること（絞っていなければ T1 側でフィルタを足す） |
| E-8 | タイムゾーン | `renewalOn` の比較は既存の `DateFormatting.daysUntil` と同じ扱いに揃える。新しい日付計算を作らない |

## 7. 検証ゲート（完了条件）

```bash
swift test --package-path meigicho/Packages/Domain
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
```

加えて T2 の手動確認手順 1〜7。

## 8. ハンドオフ

1. T1 + T3 を `swift-developer` へ並列委譲（T1 は「まず `.claude/skills/implementing-robustly/SKILL.md` を読む」を指示に含める）
2. T1 完了後に T2 を `swift-developer` へ委譲
3. **別セッションで** `code-reviewer` を呼び、差分（`main...HEAD`）をレビュー。結果は `docs/plans/identity-grouping/review.md`
   - 重点観点: IOS-1（未配線）/ IOS-5（依存の逆流）/ NFR-4（広告枠）/ NFR-5（`List` 化していないか）
