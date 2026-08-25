# membership-full-number — Code Review

- レビュー日: 2026-08-21
- 対象: `feat/relax-free-identity-limit` worktree (`.claude/worktrees/feat-membership-full-number`) の**未コミット working tree 全差分**（41 ファイル / +364 -192）
  - 注: 本機能のコミットはまだ無い（`git log main..HEAD` は本機能と無関係の 2 件のみ）
- 仕様の正: `docs/plans/membership-full-number/plan.md` / `requirements.md`（**メインリポジトリ側にのみ存在。worktree には無い** — 中-4 参照）
- レビュアー: code-reviewer（第三者セッション。実装は行っていない）

## レビュー結果サマリ

- 重大: 1 件
- 中: 4 件
- 軽微/提案: 6 件

**マージ可否**: 重大-1（デプロイ時の DB 列リネーム）に手当て（実行または「対象 DB 無し」の確認記録）を入れれば **merge 可**。
コード品質・契約整合・テストは良好で、コード側の修正必須事項は無い。中-1〜4 は docs / UX の詰め。

---

## 重大 (Must Fix)

### 重大-1 `main` マージ = Cloud Run 自動デプロイだが、本番 DB の列リネームが自動では走らない

- `apps/api/prisma/schema.prisma:131` `memberNoLast4 @map("member_no_last4")` → `memberNo @map("member_no")`
- `.github/workflows/deploy-api.yml` は `main` への `apps/api/**` 変更で test → build → Cloud Run デプロイまで自動実行する（`on.push.branches: [main]` + `paths`）
- 一方 `apps/api/docker-entrypoint.sh:7-10` は `NODE_ENV=production` で `prisma db push` を**明示的にスキップ**する

このため、Cloud Run + Supabase の実インスタンスが生きている場合、マージ直後に配備された新コードは
`member_no` 列を要求するが DB には `member_no_last4` しか無い状態になり、
**memberships の REST 全経路 + `sync/pull` + `sync/push` が `column memberships.member_no does not exist` で落ちる**。
`Membership` を select する経路は全滅するため、影響は会員情報だけに留まらない（同期バッチ全体が失敗する）。

ローカル Docker DB は移行済みであることを確認した（`meigicho-db` の `information_schema.columns` に `member_no` があり `member_no_last4` は無い）。
plan T1 手順 1 もローカルしか想定していない。

**修正案（いずれか）**

1. マージ前に対象 DB へ `ALTER TABLE memberships RENAME COLUMN member_no_last4 TO member_no;` を流す（値を保つ正しい手順。`prisma db push` は drop+add になる — requirements C-3）
2. Cloud Run / Supabase の実インスタンスが存在しないことを確認し、その事実を `docs/plans/membership-full-number/plan.md` か `docs/plans/STATUS.md` に 1 行記録する（Q4 の「未配布」はクライアント配布の話であり、サーバー DB の存在有無とは別の確認である）

どちらにせよ「DB 変更を伴う PR では手で移行を打つ」という運用が `CLAUDE.md` 既知の未整備に書いてあるだけで、
この差分の中には手順が 1 行も残っていない。次に触る人が同じ判断をできるよう記録を残すこと。

---

## 中 (Should Fix)

### 中-1 `MembershipFormView.swift:73-76` の 64 文字クランプは「切り捨て」であり FR-MN-4 に反する

```swift
.onChange(of: memberNo) { _, new in
    if new.count > Self.memberNoMaxLength {
        memberNo = String(new.prefix(Self.memberNoMaxLength))
    }
}
```

- FR-MN-4 / plan D-3 は「上限は 64 文字で、**超過分は切り捨てではなく入力不可**とする」「**黙って切らない**（BE-2）」と明記している
- 実装は `prefix()` による切り捨てで、**撤去対象だった `prefix(4)` と同じ構文がそのまま残っている**（長さが 4→64 になっただけ）
- 100 文字を貼り付けると 64 文字だけが黙って残り、ユーザーには何も表示されない

実害は「64 文字超の会員番号」という稀なケースに限られるため重大には上げないが、
**この機能の存在理由そのものが「黙った切り捨ての撤去」**なので、そのまま残すのは筋が悪い。

**修正案**: 超過時は直前値へ戻す（＝入力を受け付けない）か、少なくとも `FormHint`（`FormComponents.swift:75`）で
「会員番号は 64 文字までです」を出す。後者なら既存の DesignSystem コンポーネントで足り、平仄も取れる。
どうしても現行のまま行くなら、`requirements.md` FR-MN-4 の文言を実装に合わせて直し、差異を記録すること
（仕様と実装のどちらかが必ず嘘になっている状態を残さない）。

### 中-2 撤回記述の取りこぼし 6 箇所（AC-MN-16 未達）

plan §7 の網羅 grep は `member_no_last4|memberNoLast4|下4桁|下四桁` で、
**「暗号化 / E2EE / 復号」だけを含む記述を拾えない**。実際に以下が旧仕様のまま残っている。

| # | 場所 | 現在の記述 | 問題 |
|---|---|---|---|
| a | `docs/08-compliance-risk.md:781` | R4 対策「会員番号の任意化・**E2EE**（2.2 / 2.3）」 | 参照先 §2.3 は撤回済み。R4 は「致命的」影響のリスク行なので放置は危険 |
| b | `docs/08-compliance-risk.md:787` | R10「機種変更で会員番号が**復号不能**になり問い合わせが発生」 | 暗号化しないのでリスク自体が消滅。§2.4（撤回済み）を対策として参照している |
| c | `docs/08-compliance-risk.md:805` | §6.1「R4 会員番号の任意化と**暗号化** … データモデルに関わるため後付け不可」 | 同上 |
| d | `docs/08-compliance-risk.md:445` | §2.5 エクスポート「会員番号は**復号して**含める」 | 復号する対象が無い |
| e | `docs/02-architecture.md:351` | §7 未決事項 Q1「会員番号の**暗号化鍵** / 端末Keychainのみ or サーバー側も保持 / Phase 1」 | 撤回により論点自体が消滅。`docs/02` は plan T5 の対象外だったが AC-MN-16 の対象 |
| f | `docs/09-roadmap.md:219` | ガント `会員番号の暗号化保存 :p13, after p12, 6d` | **同一ファイル内で矛盾**。85 行目は工数 `~~2.0~~ **0**` に落としたのにガントには 6 日が残る |

f は `docs/09-roadmap.md:222` の `オンボーディング・空状態 :p15, after p13, 6d` が `p13` に依存しているため、
行を消すだけだと依存チェーンが壊れる。`after p12` へ付け替えること。

補足（軽微・実害小）: `docs/09-roadmap.md:314` の「入力率が30%未満なら暗号化の工数が無駄になっていた」は
過去形の記述なので必須ではないが、βの検証項目として残すなら現行仕様に合わせたい。

### 中-3 `docs/12-app-store-release.md:82` の氏名行「共有時は既定でマスク」は実装と部分的に一致しない

この行は plan T5 の指示範囲外の追加編集（T5 は 会員番号行の追加のみを指示）。旧文言（「暗号化保存、下4桁表示」）が
氏名行に紛れていた明らかな誤りを直したこと自体は妥当だが、新しい文言も正確ではない。

実装（`apps/api/src/shares/board/public-share.presenter.ts`）を確認した結果:

- tour スコープの `rep_name`: `history_visible = false`（`schema.prisma:111` で `@default(false)`）のとき
  `MASKED_IDENTITY_NAME = '非公開の名義'` に置換 → **「既定でマスク」は成立**
- tour スコープの `companions`: `presenter.ts:141` で `[...row.companion_names]` を**常に平文で出力**
- identity_summary スコープの `name`: `presenter.ts:159-167` で `history_visible` によらず**常に平文で出力**（隠れるのは件数キーだけ）

App Privacy 申告は plan T5 自身が「申告と実装の不一致は審査リスク」と書いている箇所なので、
「共有時は代表者名を既定でマスク（同行者名・名義一覧の表示名はマスクしない）」等、実装どおりの粒度に直すこと。

なお `docs/08-compliance-risk.md:284`（対策 5）の「氏名は既定で『佐藤 陽○』形式」も実装（`非公開の名義`）と食い違っているが、
これは本変更以前からの乖離で、plan が明示的に「変更しない」としている行なのでスコープ外として記録に留める。

### 中-4 計画産物が worktree に無く、コミットに含まれない

- `docs/plans/membership-full-number/{plan.md,requirements.md,questions-requirements.md}` は
  **メインリポジトリの作業ツリーに untracked で存在するだけ**で、この worktree には存在しない（本 review.md 作成時にディレクトリを新規作成した）
- `.claude/rules/01-aidlc.md`「計画産物は `docs/plans/<feature>/` に置き、リポジトリにコミットする」に反する
- `docs/09-roadmap.md:85` が `docs/plans/membership-full-number/` を参照しているため、このままコミットすると**リンク切れ**になる
- plan §8 手順 7「`docs/plans/STATUS.md` に『2026-08-20 会員番号の暗号化保存・下4桁表示を撤回。共有マスキングは維持』を 1 行追加」も未実施（`STATUS.md` は無変更）

**修正案**: plan / requirements / questions を worktree へコピーし、本 review.md と STATUS.md 追記と合わせて同一コミットに含める。

---

## 軽微 / 提案 (Nice to Have)

### 軽微-1 `FormComponents.swift:248-249` の `.truncationMode(.middle)` は AC-MN-13 と緊張関係にある

plan T4-1 / E-6 が明示的に許可した実装なので指摘ではなく確認事項。
ただし本機能の動機は「利用者が自分の会員番号を確認できない」ことの解消であり、
長い番号が中略されて読めないと同じ不満が形を変えて残る。カード幅に入らない番号を確認する手段が現状ゼロ
（タップは編集シートへ遷移するので実質確認できるが、UI の意図としては明示されていない）。
`.lineLimit(2)` か `.textSelection(.enabled)` の追加を提案する。

### 軽微-2 64 文字の数え方が iOS と BE で違う

- BE: `@MaxLength(64)`（class-validator → `String.prototype.length` = UTF-16 コードユニット数）
- iOS: `MembershipFormView.swift:74` の `new.count`（= 書記素クラスタ数）

絵文字やサロゲートペアを含む 64 文字は iOS を通過して REST で 400 になる。会員番号では現実的に起きないが、
将来同じパターンを他フィールドへ広げるときは注意。

### 軽微-3 `sync/push` は `member_no` を長さも制御文字も検証しない

`sync-payload.mapper.ts:44` は `payload.member_no ?? null` をそのまま Prisma へ渡し、
`sync.dto.ts` の `payload` は `@IsObject()` のみ。つまり **DTO の 64 文字・制御文字制限は REST 経路にしか効かない**。
`docs/05-ios-client.md:341` のとおり iOS の書き込み主経路は sync push なので、実質バリデーションは効いていない。

ただしこれは `fan_club_name_raw` など**全フィールド共通の既存の穴**であり、本変更が作ったものではない（BE-9 の該当ではない — 
本変更は 2 経路とも漏れなく追従しており、AC-MN-07 / AC-MN-08 の spec も両方に入っている）。
別途 `sync` 側の payload 検証を課題として立てるかの判断のみ。

### 軽微-4 iOS のトリムが `.whitespaces` で改行を落とさない

`MembershipFormView.swift:203,224` / `MembershipEditPlanner.swift:43` は `.trimmingCharacters(in: .whitespaces)`。
BE が制御文字（改行含む）を 400 で弾くようになったので、`.whitespacesAndNewlines` に揃えるほうが整合する。
`FormTextField` は単一行 `TextField`（`FormComponents.swift:69`）なので実際に改行が入る余地はほぼ無く、既存挙動との平仄も取れているため優先度は低い。

### 軽微-5 SwiftData のプロパティ改名を `SchemaV1` のまま行っている

`MembershipRecord.memberNoLast4` → `memberNo`（`MembershipRecord.swift:13`）に対し、
`SchemaV1.swift:7` の `versionIdentifier` は `1.0.0` のまま、`MeigichoMigrationPlan.stages` は空。
`@Attribute(originalName:)` も付けていない（plan Q6=A のとおり）。
`SchemaV1.swift:5` に「出荷前のためバージョンは V1 のまま拡張する」と明記されており既存方針どおりなので指摘ではないが、
**既存インストールのローカル DB では会員番号が消える**。
T4 の手動確認（AC-MN-12〜15）を実機/シミュレータで行う前に、必ずアプリを削除してから入れ直すこと。

### 軽微-6 `member_no` の nullable 型が POST と PATCH で揃っていない

- `create-membership.dto.ts:44` `member_no?: string`
- `update-membership.dto.ts:41` `member_no?: string | null`

plan §2.2 は POST も「省略可・`null` 可」としており、実際 `@IsOptional()` が `null` を素通しして
`memberships.service.ts:78` の `?? null` で保存される。挙動は正しいが型注釈だけが実態と違う。
`update` 側は `renewal_on` / `note` と同じ書き方で平仄が取れているので、`create` 側を `string | null` に寄せるのが素直。

なお `{"member_no": null}` を POST / PATCH した場合に DTO 検証を通ることの spec は無い（service spec のみ）。
将来 `@IsOptional()` を `@ValidateIf` 等に変えたときに気付けないので、`create-membership.dto.spec.ts` に 1 ケース足すと安い保険になる。

---

## 検証したこと（レビュアー自身の実行結果）

| 項目 | 結果 |
|---|---|
| `cd apps/api && npx tsc --noEmit` | クリーン（= Prisma Client が `memberNo` で再生成済み） |
| `cd apps/api && npx jest src/memberships src/sync src/shares` | 30 suites / 371 tests 全 pass |
| `swift test --package-path meigicho/Packages/Domain` | 277 tests pass |
| `swift test --package-path meigicho/Packages/Networking` | 167 tests pass |
| `swift test --package-path meigicho/Packages/DataStore` | 50 tests pass |
| ローカル DB の列 | `meigicho-db` の `memberships` に `member_no` があり `member_no_last4` は無い（`db push` 適用済み） |
| `xcodebuild` | 未実行（オーケストレーター確認済みとの申告。パッケージ 3 本の test 成功で代替確認とした） |

### 観点別チェック結果

- **アーキテクチャ**: BE は Controller → UseCase → Service → Prisma を維持（`memberships.service.ts` / `sync-*.ts` のみ変更、Prisma 直叩きの新規追加なし・BE-3 OK）。
  iOS は Domain / Networking / DataStore / DesignSystem / Features のいずれも既存の層をまたいでいない。Domain に SwiftData の混入なし（IOS-5 OK）
- **API 契約 3 層**: `schema.prisma:131` `member_no` ↔ BE DTO / presenter / sync serialize / sync mapper ↔
  iOS `MembershipDTO.swift`（response / create / patch の 3 DTO + CodingKeys）/ `MembershipRecord+SyncPayload.swift`（push キー・pull 読み取り）/ `Models.swift` / `Patches.swift` を突き合わせ、**全て一致**。UUID 前提の変更なし
- **BE-8（whitelist 検証）**: `create-membership.dto.spec.ts:12-17` の `validateBody` が
  `validate(dto, { whitelist: true, forbidNonWhitelisted: true })` を使っている。AC-MN-02 は `errors.some(e => e.property === 'member_no_last4')` まで確認していて手堅い
- **BE-9（書き込み経路 2 本）**: REST（`memberships.service.ts:78,110,184`）と sync（`sync-payload.mapper.ts:44` / `sync-serialize.ts:34`）の
  **4 箇所すべて**が追従済み。spec も AC-MN-07（push）/ AC-MN-08（pull・`not.toHaveProperty('member_no_last4')`）の両方がある。**追従漏れなし**
- **BE-2（黙殺フォールバック）**: BE 側は `@MaxLength(64)` 超過を 400 で返す（黙って切らない）。iOS 側は 中-1 参照
- **IOS-2（パース追従漏れ）**: `grep -rn "member_no_last4\|memberNoLast4" apps/api/src apps/api/prisma meigicho/Packages meigicho/App` の残存ヒットは
  ①`shares` の禁止キー検査 2 件（意図的・無変更）②DTO のコメント 2 件（「受理しない」の説明）
  ③spec / テストの否定アサーション 4 件 のみ。**実処理コードに旧名の残存なし**
- **セキュリティ / D-4**: `apps/api/src/shares/` は 1 ファイルも変更されていない（`git status` で確認）。
  `public-share.presenter.ts` は board ペイロードを明示キーで組み立てており会員番号を一切参照しない。
  `identity-summary.service.ts` も membership を触らない。`resolve-share` / `update-share-item` の禁止キー検査は無変更で pass（AC-MN-09 回帰確認 OK）。
  Guard / ownerId スコープに変更なし（BE-4 OK）。`.env` / 秘密鍵の混入なし
- **平仄**: DTO の decorator 並び（`@IsOptional` → `@IsString` → `@MinLength` → `@MaxLength` → `@Matches`）は
  `fan_club_name_raw` と同形。iOS の `Patchable` / `SyncPayloadBuilder.optionalString` / `SyncField.string` の使い方も既存どおり

## 良かった点

- **BE-9 が本当に塞がっている**。1 フィールドの改名で REST 2 経路 + sync 2 経路 + presenter を漏れなく追い、
  さらに「pull に旧キーが出ないこと」を `not.toHaveProperty` で否定側から固定している（`sync.service.spec.ts:120-124`）。
  改名系タスクで最も落としやすい所を spec で押さえている
- **D-2 の意図がテストに翻訳されている**。全角（`会員番号４８２１`）・記号混じり（`STL-04821`）が通ること、
  65 文字 / 空文字 / 改行が落ちることを個別ケースにしていて、「文字種を絞らない」という設計判断が
  将来のリファクタで巻き戻らないよう固定されている。64 文字ちょうどの境界ケースまである
- **撤回を「消さずに記録する」方針（D-5）が徹底されている**。`docs/08` §2.3 の E2EE 判断は
  トレードオフ表ごと残したうえで結論だけ差し替えており、なぜ対策が無いのかの経緯が読み取れる。
  `docs/09` の 0-13 も取り消し線 + 工数 0 + 合計の再計算（57.5 → 55.5）まで整合している
- **リスク台帳の悪化を正直に書いている**。R20 の影響度を「中→高」に引き上げ、`CLAUDE.md` と
  `docs/08:462` の両方に「会員番号の平文保存についての法務確認」を本番前必須として追加している。
  自分に不利な方向のリスク更新を省略していない
- **FR-MN-10 の注記が実装の事実に基づいている**。`docs/04-api.md:467` の
  「board ペイロードに会員番号が含まれないため、現状このフラグは board の内容に影響しない」は
  presenter の実装と一致しており、「フラグを残すが効かない」という紛らわしい状態を明文化できている
