# plan — admob-integration

前提: `requirements.md`（要件・現状把握）と `api-contract-delta.md`（契約の正）を先に読むこと。
未確定事項は `questions-requirements.md`。**Q1〜Q4 の回答前に実装へ着手しない。**

---

## 1. ゴール

`docs/09-roadmap.md` Phase 1 の 1-11（AdMob 組み込み）と 1-10 の広告部分を実装可能な状態にする。
成果は 3 つ:

1. **広告基盤** — `AdPlacement`（許可面のみの型ガード）+ `AdGatekeeper`（表示可否の純粋判定）+ `AdSlot`（DADS 準拠の描画）
2. **広告配置** — バナー 3 面 + ネイティブ 2 面（`requirements.md` F2）
3. **リワード縦串** — `POST /v1/rewards/claims` → AdMob リワード動画 → SSV → `entitlements` 付与 → iOS 反映

---

## 2. 影響範囲（層チェックリスト）

| 層 | 影響 |
|---|---|
| **DB** | `apps/api/prisma/schema.prisma` — `Entitlement` に 2 カラム / `RewardedAdClaim` 新設 / `User` にリレーション |
| **BE** | 新設 `src/rewards/`（controller / use-case / service / dto）、新設 `src/rewards/admob-ssv.*`、改修 `src/entitlements/entitlements.service.ts`（視聴回数の読み取り）、改修 `src/me/me.service.ts`（3 キー追加 + 削除順）、改修 `src/common/` の `ErrorCode`、`src/app.module.ts` |
| **iOS Domain** | 新設 `Ads/AdPlacement.swift` / `Ads/AdGatekeeper.swift` / `Stores/AdsStore.swift`、改修 `Models/AccountModels.swift`（`Entitlement` 3 プロパティ）、新設 Repository protocol `RewardsRepository` |
| **iOS DesignSystem** | 新設 `Ads/AdSlot.swift` / `Ads/AdRenderer.swift`（protocol + Environment key）/ `Ads/AdCardChrome.swift`（広告ラベル・カード枠） |
| **iOS Network** | 新設 `DTO/RewardsDTO.swift` / `Repositories/RemoteRewardsRepository.swift`、改修 `DTO/MeDTO.swift` |
| **iOS App** | 新設 `Ads/GoogleMobileAdsRenderer.swift` / `Ads/DisabledAdRenderer.swift` / `Ads/AdRendererFactory.swift` / `Ads/AdsInitializer.swift`、改修 `AppEnvironment.swift`、改修 `project.yml`（SPM 依存 + 7 設定） |
| **iOS Features** | 改修 `Home/HomeView.swift` / `Identities/IdentityListView.swift` / `Applications/ApplicationListView.swift` / `Detail/IdentityDetailView.swift` / `Monetization/PaywallView.swift` |
| **docs** | `docs/04-api.md`（3 エンドポイント追記）/ `docs/03-database.md`（2 テーブル差分）/ `docs/05-ios-client.md:864-890`（矛盾修正）/ `docs/09-roadmap.md:104-105, 534`（ATT・工数）/ `docs/plans/STATUS.md` §6 |

---

## 3. エッジケース（機械的列挙）

| # | ケース | 扱い |
|---|---|---|
| E1 | 広告ユニット ID が空 | SDK を初期化しない。`AdSlot` は描画しない（高さ 0）。クラッシュしない |
| E2 | オフライン | 枠自体を出さない（`AdGatekeeper` が false）。空枠を残さない |
| E3 | 広告のロード失敗 | プレースホルダを消し高さ 0 に戻す。リトライしない（同一セッション） |
| E4 | 画像取得失敗（ネイティブ） | テキストのみで描画。空枠を残さない（`docs/07:448`） |
| E5 | Plus → Free に変わった直後 | `AdsStore` は `entitlement` の変化を監視し、次のフレームから広告を出す。逆方向は即座に非表示 |
| E6 | リワード視聴中にアプリがバックグラウンド → SSV が先に届く | claim は `granted` 済み。復帰後のポーリング初回で `granted` を取得できる |
| E7 | SSV が届かない（AdMob 障害・ネットワーク） | 15 秒ポーリングでタイムアウト → iOS は「反映に時間がかかっています。しばらくして再度お確かめください」を表示。claim は 15 分後に `expired` |
| E8 | SSV の重複配信 | `transaction_id` UNIQUE → P2002 → 200 no-op（二重付与なし） |
| E9 | 同一ユーザーが同時に 2 つの claim を作る | 新規発行時に古い `pending` を `expired` にする |
| E10 | 月をまたいだ瞬間の視聴 | 読み取り時に `rewarded_views_reset_at < JST当月1日` なら 0 扱い。書き込み時に `reset_at` を JST 当月 1 日で上書き |
| E11 | ボーナス期限ちょうど（`bonus_expires_at == now`） | **無効**（既存 `entitlements.service.ts:90` の `<=` を維持。テスト済み） |
| E12 | claim 発行後に Plus を購入 → SSV 到着 | 付与処理 §5.1-6 で再検証し `rejected("plus")` |
| E13 | 申込一覧が 5 件未満 | ネイティブ広告を挿入しない（インデックス計算のゼロ件境界） |
| E14 | ツアー表の `tour-group` が 1 つだけ | 「グループ間」が存在しないので広告を出さない |
| E15 | アカウント削除 | `rewarded_ad_claims` を削除順に含める（`api-contract-delta.md` §1.3） |
| E16 | ステータス変更 60 秒クールダウン中に画面遷移 | クールダウンはグローバル（`AdsStore` が保持）。画面をまたいで有効 |
| E17 | 通知タップからの起動 | `AdGatekeeper` の起動 30 秒ルールで自然に抑止される。加えて F3-7 の対象画面には `AdSlot` を置かない |
| E18 | Dynamic Type 最大 | 広告カードの高さが伸びる。プレースホルダ高さは固定だが `minHeight` で扱い、はみ出さないこと |

---

## 4. 設計判断（採用案 + 却下案）

### D1. `Network` パッケージ名衝突は Spike で先に潰す

**採用**: Wave 0 で SPM 依存追加のみのクリーンビルド Spike（T0）を行い、結果で分岐する。
**却下**: (a) 何もせず実装を進める → RevenueCat で実害が出た前例がある（`docs/plans/STATUS.md` §3）。ビルドが通らないと以降のタスクが全部止まる。(b) 先にリネームする → 衝突しない可能性があるのに大きい差分を先に入れると、AdMob の問題とリネームの問題が混ざって切り分け不能になる。

### D2. 広告表示の可否判定を `Domain` の純粋型 `AdGatekeeper` に集約する

**採用**: `requirements.md` F4-1〜F4-6 の 6 条件（Plus / 起動 30 秒 / セッション 3 枚 / 同一画面連続 2 枚 / オフライン / ステータス変更 60 秒）を、SDK に触れない純粋な struct として `meigicho/Packages/Domain/Sources/Domain/Ads/AdGatekeeper.swift` に置く。View 側は結果を受け取るだけ。
**理由**: `.claude/rules/01-aidlc.md`「iOS の振る舞いロジックは Domain / Core の純粋関数か BE に寄せる。XCTest が未整備なら…」。`Domain` には既に 138 件のテストがあり、ここに置けば**リワード以外の広告ロジックを機械ゲートで検証できる**。
**却下**: (a) `AdSlot` の `body` に条件を直書き → テスト不能・重複・条件の追加漏れ。(b) BE に寄せる → 表示頻度はクライアント状態（セッション・スクロール位置）に依存し、サーバーが知らない。

### D3. 禁止領域は「許可面だけを列挙する enum」で担保する

**採用**:
```swift
public enum AdPlacement: String, CaseIterable, Sendable {
    case homeBottom, identitiesBottom, applicationsInline, tourTableBetween, identityDetailBottom
}
```
禁止面は **case として存在しない** → 禁止画面では `AdSlot(placement:)` の引数が作れない。
加えて `AdSlotForbiddenScreensTests`（`Domain` or 新テストターゲット）で、`requirements.md` F3 の禁止画面ソースファイルに文字列 `AdSlot` が出現しないことを検査する。

**却下**: `docs/05:864-872` の「禁止面も case に持ち `allowsAds: Bool` で false を返す」案。`allowsAds` を 1 行書き換えるだけで広告を出せてしまい、`docs/07:407`「フラグで消せる設計にすると、将来の収益改善圧で必ず戻される」という設計意図を満たさない。**設計の変更ではなく、同じ意図をより強い手段で実現する強化**として扱う（`docs/05` の当該箇所は修正対象）。

### D4. `Features` は広告 SDK を参照しない（`AdRenderer` protocol + Environment 注入）

**採用**: 3 段構成。
- `Domain/Ads/` — `AdPlacement`・`AdGatekeeper`・`AdsStore`（SDK 非依存）
- `DesignSystem/Ads/AdSlot.swift` — `@Environment(\.adRenderer)` で `(any AdRenderer)?` を取得し、`nil` なら何も描画しない。DADS トークンでカード枠と「広告」ラベルを描く
- `App/Ads/GoogleMobileAdsRenderer.swift` — `#if canImport(GoogleMobileAds)` で SDK を封じ込め、Composition Root（`AppEnvironment.swift`）で注入

**理由**: IOS-5（Features がインフラ層を直接参照しない）。既存の `PurchasesServiceFactory` + `DisabledPurchasesService`（`meigicho/App/Purchases/`）と同じ構造で、実績のあるパターン。
**却下**: (a) `Features` が SDK に直接依存 → IOS-5 違反。SDK 未導入時にパッケージ単体テストが壊れる。(b) 新パッケージ `Ads` を作り `Features` が依存 → 依存の向きは正しいが、`Features` のビルドに SDK が必要になり単体テストが重くなる。

### D5. SSV はサーバーが唯一の正。クライアント楽観更新と Outbox は使わない

**採用**: `api-contract-delta.md` §3〜§5 の claim 方式。クライアントは付与を**書かない**。
**却下**: `docs/05:887` の「ローカル即時反映し Outbox 経由でサーバーへ」→ 改造クライアントで無制限に枠を増やせる（`docs/08` R15）。`docs/07:435` / `docs/08:645, 785` が 3 箇所でサーバー判定を要求している。詳細と根拠は `questions-requirements.md` Q7。

### D6. claim（事前登録）方式 vs `/v1/me` 単純ポーリング

**採用**: claim 方式。
**理由**: ① 月 2 回上限を**視聴前に**サーバー判定できる（`docs/07:435`「クライアント値は信用しない」）→ 見終わってから「上限です」と言わずに済む。② `custom_data` に載せる不可推測な ID がリプレイ・なりすまし対策になる。③ 視聴試行のログ（F6-7）が自然に取れる。
**却下**: 視聴完了後に `GET /v1/me` を叩き続けるだけの案 → 事前の資格判定ができず、`transaction_id` 以外に「どの視聴に対する付与か」を紐づける手段がない。

### D7. SSV の署名検証は raw query から行う

**採用**: `@Req()` で `req.originalUrl` を受け、`&signature=` の直前までを検証対象にする。
**却下**: `@Query()` のパース結果からクエリ文字列を再構築する案 → キー順序と URL エンコードが変わり、署名検証が必ず失敗する。**この落とし穴を `api-contract-delta.md` §5 に明記済み**。

### D8. 検証鍵は Google 公開鍵。秘密情報を持たない

`questions-requirements.md` Q6 参照。Secret Manager / KMS を増やさない。

### D9. リワード付与時は `bonusIdentitySlots` を「1 に固定」する（加算しない）

`docs/07:415` の「同時に持てるボーナス枠は 1 枠まで（+2 不可）」を、`= 1` の代入で担保する。`+= 1` は Q3 が 2 に確定した場合のみ検討（その場合も上限クランプが必要）。

---

## 5. タスク分解

**Wave 内は並列可、Wave 間は直列。** 担当エージェントは `.claude/rules/02-agents.md` に従う。

### Wave 0 — Spike（直列・最優先 / 担当: swift-developer, model: sonnet）

| ID | 内容 | 完了条件 |
|---|---|---|
| **T0** | `meigicho/project.yml` に `GoogleMobileAds`（`https://github.com/googleads/swift-package-manager-google-mobile-ads`, from 11.0.0）を追加し、`xcodegen` → **完全クリーンビルド**（`Package.resolved` 削除 + `/tmp/meigicho-build` 削除）。`import GoogleMobileAds` を書いた 1 ファイルだけを追加して衝突有無を確認する | BUILD SUCCEEDED か、失敗ログ（特に `Network` モジュール解決エラー）を報告 |
| **T0b** | （T0 が失敗したときのみ）`Network` パッケージを `MeigichoAPI` へリネーム。`Packages/Network/` ディレクトリ名・`Package.swift`・`project.yml`・`import Network` 21 ファイル（`App/AppEnvironment.swift`・`App/DeepLinkRouter.swift`・`Packages/Network/Tests/**`）を機械的に置換 | クリーンビルド + Core/Domain/Network の `swift test` 全緑 |

**T0 の結果は以降すべての iOS タスクの前提。オーケストレーターが結果を確認してから Wave 1 を発行する。**

### Wave 1 — BE（直列 1 エージェント / 担当: nest-developer, model: **opus**）

複数モジュール新規 + 署名検証（前例なし設計）のため `.claude/rules/02-agents.md` のエスカレーション条件に該当。
`schema.prisma` を触るため **1 エージェントが直列で実施**（rule 03: DB 変更中の並列実装は禁止）。

| ID | 内容 | AC |
|---|---|---|
| **T1** | `schema.prisma`: `Entitlement` に 2 カラム / `RewardedAdClaim` 新設 / `User` リレーション。`cd apps/api && npx prisma db push` | AC-AD-15 |
| **T2** | `entitlements.service.ts` に `rewardedViews(userId)`（JST 月境界の遅延リセット読み取り）を追加。`me.service.ts` の `MeEntitlementView` に 3 キー追加 + `DELETE /v1/me` 削除順に `rewardedAdClaim` 追加 | AC-AD-14, AC-AD-16, AC-AD-04 |
| **T3** | `src/rewards/` 新設: `POST /v1/rewards/claims` + `GET /v1/rewards/claims/:claim_id`。Controller → UseCase → Service → Prisma。`ErrorCode` に 3 値追加 | AC-AD-01〜05, AC-AD-13 |
| **T4** | `src/rewards/admob-ssv.*`: `GET /v1/webhooks/admob-ssv`。raw query 署名検証（D7）+ 鍵キャッシュ + 付与トランザクション | AC-AD-06〜12 |

**T1 → T2 → T3 → T4 の順**（T4 は T3 の claim モデルに依存）。

### Wave 1' — iOS Domain（Wave 1 と**並列可** / 担当: swift-developer, model: sonnet）

BE のコードに依存しない純粋型のみ。契約は `api-contract-delta.md` で確定済みなので待つ必要がない。

| ID | 内容 | AC |
|---|---|---|
| **T5** | `Domain/Ads/AdPlacement.swift`（許可 5 面 + リワードは別型）、`Domain/Ads/AdGatekeeper.swift`（F4 の 6 条件）、`Domain/Stores/AdsStore.swift`（`@Observable`・セッション状態保持）。XCTest 付き | AC-AD-20〜26 |
| **T6** | `Domain/Models/AccountModels.swift` の `Entitlement` に 3 プロパティ追加 + `RewardsRepository` protocol 定義 + `RewardClaim` / `RewardClaimStatus` モデル | AC-AD-14（iOS 側） |

### Wave 2 — iOS 実装（並列 3 本 / 担当: swift-developer, model: sonnet）

| ID | 内容 | 依存 | AC |
|---|---|---|---|
| **T7** | `Network/DTO/RewardsDTO.swift` + `Network/Repositories/RemoteRewardsRepository.swift` + `Network/DTO/MeDTO.swift` の 3 キー追従 + DTO テスト | T6 | AC-AD-30, 31 |
| **T8** | `DesignSystem/Ads/`: `AdRenderer` protocol + `EnvironmentKey`、`AdSlot`（Plus/gatekeeper で非描画・高さ 0）、`AdCardChrome`（「広告」ラベル・カードトークン・14px 下限・推しカラー非適用） | T5 | AC-AD-27, 32〜35 |
| **T9** | `App/Ads/`: `AdRendererFactory`（ユニット ID 空なら `DisabledAdRenderer`）、`GoogleMobileAdsRenderer`（`#if canImport` / バナー + ネイティブカスタムレイアウト + リワード）、`AdsInitializer`（`Task.detached(.utility)` / `npa=1`）、`project.yml` の 7 設定と Info.plist | T0 | AC-AD-36〜38 |

**T9 は `project.yml` を単独所有**（T0b と同じファイル → T0b 完了後に着手）。

### Wave 3 — 配線（並列 2 本 / 担当: swift-developer, model: sonnet）

| ID | 内容 | 依存 |
|---|---|---|
| **T10** | `Features` 4 画面への `AdSlot` 配置（`HomeView` / `IdentityListView` / `ApplicationListView`（リスト + ツアー表）/ `IdentityDetailView`）。`AppEnvironment.swift` で `AdsStore` と `adRenderer` を注入 | T8, T9 |
| **T11** | `PaywallView.swift:49-52` のプレースホルダをリワード導線に差し替え。claim 作成 → リワード表示 → ポーリング（1 秒 × 最大 15 回）→ 結果表示。Plus 時は導線非表示 | T7, T9 |

**T10 と T11 は `AppEnvironment.swift` が競合しうる** → `AppEnvironment.swift` の編集は **T10 が単独所有**。T11 は Store 経由でのみアクセスする。

### Wave 4 — docs + レビュー（直列）

| ID | 内容 | 担当 |
|---|---|---|
| **T12** | `docs/04-api.md`（3 エンドポイント）、`docs/03-database.md`（2 テーブル差分）、`docs/05-ios-client.md:864-890`（Q2/Q3/Q7 の矛盾修正）、`docs/09-roadmap.md:104-105, 534`（ATT 記述と工数）、`docs/plans/STATUS.md` §6 | nest-developer or 手元 |
| **T13** | **別セッションで** `code-reviewer`。差分は `main...HEAD`。結果は `docs/plans/admob-integration/review.md` | code-reviewer, model: opus |

---

## 6. 並列実行可能なタスク

| Wave | 並列に発行してよい組 | 直列必須の理由 |
|---|---|---|
| 0 | なし（T0 単独） | 全 iOS タスクの前提 |
| 1 | **{T1→T2→T3→T4}（BE 1 本）** と **{T5, T6}（iOS Domain 2 本）** は**並列可** | BE 内は `schema.prisma` 共有のため直列。T5/T6 は互いに別ファイル |
| 2 | **T7 / T8 / T9 は 3 本並列可** | 触るパッケージが Network / DesignSystem / App で完全に分離 |
| 3 | **T10 / T11 は並列可**（`AppEnvironment.swift` は T10 が単独所有） | — |
| 4 | なし | レビューは集約（rule 03） |

**絶対に並列にしないもの**: `apps/api/prisma/schema.prisma`・`apps/api/src/app.module.ts`・`meigicho/project.yml`・`meigicho/App/AppEnvironment.swift`。

### 工数見積（planner 実測ベース。`docs/09` の 4.0 人日を超える → Q4）

| Wave | タスク | 人日 |
|---|---|---|
| 0 | T0 Spike | 0.5 |
| 0 | T0b リネーム（条件付き） | 0.5〜1.0 |
| 1 | T1〜T4（BE。うち T4 SSV が 1.5） | 2.5〜3.0 |
| 1' | T5, T6 | 1.0 |
| 2 | T7 | 0.5 |
| 2 | T8 | 1.0 |
| 2 | T9（ネイティブカスタムレイアウトが重い） | 1.5〜2.0 |
| 3 | T10 | 1.0 |
| 3 | T11 | 0.5 |
| 4 | T12, T13 | 0.5 |
| | **合計** | **9.0〜10.5** |

Q4 で段階リリース（案 B）を選ぶ場合の分割:
- **Stage 1（≈4.0 人日）**: T0(+T0b) → T5(AdPlacement/AdGatekeeper) → T8 → T9(バナーのみ) → T10(バナー 3 面: 名義一覧・ツアー表・名義詳細) → T13
- **Stage 2（≈5.5 人日）**: T1〜T4 → T6 → T7 → T9(ネイティブ + リワード追加) → T10(ホーム・申込一覧のネイティブ) → T11 → T12 → T13

---

## 7. ファイル所有表（同時に触らせない）

| ファイル | 単独所有タスク | 備考 |
|---|---|---|
| `apps/api/prisma/schema.prisma` | **T1** | T2〜T4 は読み取りのみ |
| `apps/api/src/app.module.ts` | **T3** | T4 は T3 が作った `RewardsModule` に足す（同一エージェント直列なので安全） |
| `apps/api/src/entitlements/entitlements.service.ts` | **T2** | |
| `apps/api/src/me/me.service.ts` | **T2** | |
| `apps/api/src/common/**`（ErrorCode） | **T3** | |
| `apps/api/src/rewards/**` | **T3 → T4** | 同一エージェント直列 |
| `meigicho/project.yml` | **T0 → T0b → T9** | 3 タスクとも直列。並列発行禁止 |
| `meigicho/App/AppEnvironment.swift` | **T10** | T11 は触らない |
| `meigicho/App/Ads/**` | **T9** | |
| `meigicho/Packages/Domain/Sources/Domain/Ads/**` | **T5** | |
| `meigicho/Packages/Domain/Sources/Domain/Stores/AdsStore.swift` | **T5** | |
| `meigicho/Packages/Domain/Sources/Domain/Models/AccountModels.swift` | **T6** | T5 は触らない |
| `meigicho/Packages/Network/**` | **T7** | |
| `meigicho/Packages/DesignSystem/Sources/DesignSystem/Ads/**` | **T8** | |
| `meigicho/Packages/Features/**/HomeView.swift` 等 4 画面 | **T10** | |
| `meigicho/Packages/Features/Sources/Features/Monetization/PaywallView.swift` | **T11** | |

---

## 8. 受入基準 → テストケース

### 8.1 BE（`apps/api` / jest。テスト先行 Red → Green）

| AC-ID | 受入基準 | テストファイル |
|---|---|---|
| AC-AD-01 | free ユーザーが `POST /v1/rewards/claims` → 201、`custom_data == claim_id`、`remaining_views_this_month == 1` | `rewards/rewards.service.spec.ts` |
| AC-AD-02 | `plan="plus"` → `REWARD_NOT_APPLICABLE` 409。`in_grace_period=true` も同様 | 同上 |
| AC-AD-03 | JST 当月の視聴が 2 回 → `PLAN_LIMIT_REWARDED_VIEWS` 403、`details.reset_at` が翌月 1 日 | 同上 |
| AC-AD-04 | `rewarded_views_reset_at` が先月 → 視聴回数 0 として扱い 201 を返す（月境界の遅延リセット） | `entitlements/entitlements.service.spec.ts` |
| AC-AD-05 | `bonus_expires_at` が 8 日後 → `REWARD_SLOT_ACTIVE` 409 / 6 日後 → 201 / 期限切れ → 201 | `rewards/rewards.service.spec.ts` |
| AC-AD-06 | 正しい署名の SSV → 200・`status="granted"`・`bonus_identity_slots=1`・`bonus_expires_at = now+30日`・`rewarded_views_month` が +1 | `rewards/admob-ssv.service.spec.ts` |
| AC-AD-07 | 署名が改竄されている → 401、entitlement は不変 | 同上 |
| AC-AD-08 | 同一 `transaction_id` の再送 → 200 no-op、`bonus_identity_slots` は 1 のまま（二重付与なし・BE-6） | 同上 |
| AC-AD-09 | `timestamp` が 61 分前 / 61 分後 → 401 | 同上 |
| AC-AD-10 | `user_id` が claim の所有者と不一致 → 401、claim は `rejected("user_mismatch")` | 同上 |
| AC-AD-11 | `expires_at` を過ぎた claim への SSV → 200、`status="expired"`、付与なし | 同上 |
| AC-AD-12 | **署名対象文字列が raw query から作られる**: 同一パラメータをキー順序違いで 2 通り渡し、AdMob が送った生順序でのみ検証が通ること | 同上（D7 の回帰防止） |
| AC-AD-13 | 他ユーザーの `claim_id` に `GET` → **404**（403 ではない・BE-4） | `rewards/rewards.service.spec.ts` |
| AC-AD-14 | `GET /v1/me` の `entitlement` に `rewarded_views_this_month` / `rewarded_views_limit` / `rewarded_views_reset_at` が含まれる。plus のとき `rewarded_views_limit == 0` | `me/me.service.spec.ts` |
| AC-AD-15 | 付与後に `identityLimit(userId)` が 4 を返す（既存ロジックとの結合） | `entitlements/entitlements.service.spec.ts` |
| AC-AD-16 | `DELETE /v1/me` が `rewarded_ad_claims` も削除する（削除順に含まれる） | `me/me.service.spec.ts` |
| AC-AD-17 | `ADMOB_SSV_ENABLED=false` のとき `POST /v1/rewards/claims` と SSV がともに 503 | `rewards/*.spec.ts` |
| AC-AD-18 | 未知の `placement` → 400 `VALIDATION_ERROR`（黙って `identity_slot` に落とさない・BE-2） | `rewards/dto/*.spec.ts` or service spec |
| AC-AD-19 | 同一ユーザーの 2 回目の claim 作成で、1 回目の `pending` が `expired` になる | `rewards/rewards.service.spec.ts` |

### 8.2 iOS Domain（`swift test`。純粋ロジックなので機械ゲート可）

| AC-ID | 受入基準 |
|---|---|
| AC-AD-20 | `plan == .plus` なら `AdGatekeeper.shouldShow(...) == false`。`inGracePeriod == true` も false |
| AC-AD-21 | 起動から 29.9 秒は false、30.0 秒で true |
| AC-AD-22 | 同一セッションで 3 インプレッション到達後は false |
| AC-AD-23 | ステータス変更から 59 秒は false、61 秒で true（F4-5） |
| AC-AD-24 | `isOnline == false` なら false |
| AC-AD-25 | 同一画面で直前に 1 枚出していたら 2 枚目は false |
| AC-AD-26 | `AdPlacement.allCases.count == 5` かつ、禁止面に相当する case 名（`applicationDetail` / `sharePreview` / `sharedBoard` / `form` / `statusChange`）が**存在しない**（D3 の型ガード回帰防止） |
| AC-AD-27 | `AdSlot` の文字列が `ApplicationDetailView.swift` / `AddIdentityView.swift` / `AddMembershipView.swift` / `AddApplicationView.swift` / `SheetContentView.swift` / `SharePreviewView.swift` / `SharedBoardView.swift` / `OpenSharedBoardView.swift` に出現しない（ソース走査テスト） |
| AC-AD-28 | セッションのリセット: バックグラウンド 30 秒未満は継続、30 秒以上でカウンタが 0 に戻る（Q10） |

### 8.3 iOS Network（`swift test`）

| AC-ID | 受入基準 |
|---|---|
| AC-AD-30 | `MeDTO` が `rewarded_views_this_month` / `rewarded_views_limit` / `rewarded_views_reset_at` をパースし `Entitlement` に写す。**3 キーが欠けた JSON でも既定値でデコードできる**（後方互換） |
| AC-AD-31 | `RewardsDTO` が `POST /v1/rewards/claims` と `GET /v1/rewards/claims/:id` のレスポンスをパースする。`status` の未知値は `nil`（`pending` に落とさない）→ Repository がエラーを返す（IOS-2 / BE-2） |

### 8.4 iOS UI（機械ゲートは `xcodebuild` BUILD SUCCEEDED のみ / 手動確認手順）

| AC-ID | 手動確認 |
|---|---|
| AC-AD-32 | 名義一覧の最下部に「広告」ラベル付きカードが 1 枚だけ表示される。カードは `ticket-row` と同じ角丸・枠線・背景 |
| AC-AD-33 | 推しカラーを変更しても広告カードの色が変わらない（F5-3） |
| AC-AD-34 | 広告のロード完了時にリストが飛ばない（プレースホルダ高さ固定・F5-6） |
| AC-AD-35 | 申込詳細（`ApplicationDetailView`）・全フォーム・共有プレビュー・共有ボードに広告が一切出ない（F3） |
| AC-AD-36 | `ADMOB_APP_ID` を空にしてビルド → クラッシュせず、広告枠が高さ 0 で消える（E1 / N6） |
| AC-AD-37 | **起動 TTI が導入前後で劣化しない**（p95 < 2 秒。Instruments or `os_signpost` で 5 回計測して比較。`docs/09:534` T7） |
| AC-AD-38 | 起動直後 30 秒間は広告が出ず、30 秒後の再スクロールで出る |
| AC-AD-39 | ステータスを「当選」に変えた直後 60 秒は、一覧に戻っても広告が出ない |
| AC-AD-40 | 機内モードで広告枠が消える（空枠が残らない） |
| AC-AD-41 | **リワード縦串**: Free で名義 3 件 → 4 件目タップ → ペイウォール → 「動画を見て30日間だけ1枠増やす」→ 動画完走 → 数秒以内に「+1枠を30日間 有効にしました」→ 名義追加が通る |
| AC-AD-42 | リワード視聴後、同月にもう 1 回視聴可（2 回目）。3 回目は導線がグレーアウトし理由が表示される |
| AC-AD-43 | Plus 契約中はペイウォールにリワード導線が出ない（F6-5） |
| AC-AD-44 | SSV が届かない状況（機内モードにして動画完走）→ 15 秒後に「反映に時間がかかっています」を表示し、アプリがハングしない（E7） |

**AC-AD-41〜44 は AdMob 実アカウント + Cloud Run デプロイが前提**（Q5 U1/U2/U3）。実 ID 取得前は Google テストユニット ID + テスト SSV でのユニット検証に留める（Q9 案 A）。

---

## 9. ハンドオフ

### 9.1 委譲プロンプト案 — Wave 0 / T0（swift-developer）

```
まず /Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md を読み従うこと。

【目的】Google Mobile Ads SDK が自作 Network パッケージと衝突しないかを実測する Spike。
結果で後続の実装計画が分岐するため、実装は最小限にして事実の確定を最優先する。

【対象】/Users/yuyamorishita/オタ活アプリ/meigicho

【背景（必読）】
自作パッケージ meigicho/Packages/Network は Apple の Network.framework とモジュール名が衝突し、
RevenueCat SDK はこれが原因で現在無効化されている（meigicho/project.yml:26-30 のコメント、
docs/plans/STATUS.md の「RevenueCat（課金SDK）の一時無効化」節）。同じ事故が AdMob でも起きうる。

【やること】
1. meigicho/project.yml の packages に GoogleMobileAds を追加する
   url: https://github.com/googleads/swift-package-manager-google-mobile-ads / from: 11.0.0
   targets.Meigicho.dependencies にも product を追加する
2. meigicho/App/Ads/AdsSpike.swift を新規作成し、`import GoogleMobileAds` と
   `enum AdsSpike { static let ready = GADMobileAds.sharedInstance() != nil }` だけを書く
3. xcodegen で .xcodeproj を再生成する
4. **完全クリーンビルド**を行う（rm -rf /tmp/meigicho-build と
   meigicho/Meigicho.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved を削除してから）
   xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
     -destination 'generic/platform=iOS Simulator' \
     -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
5. 続けて cd meigicho/Packages/Network && swift test を実行する

【やらないこと】
- 広告 UI・AdSlot・リワードの実装（別タスク）
- Network パッケージのリネーム（衝突が確認されてから別タスクで行う）
- project.yml の他の設定変更

【完了条件・報告フォーマット】日本語で以下を順に:
① BUILD SUCCEEDED か FAILED か
② FAILED の場合、エラーメッセージの原文（特に "Network" モジュール解決に関する行を全文）
③ swift test の結果
④ 衝突の有無に対する結論と、リネームが必要かどうかの判断（file:line 付き）
⑤ 変更したファイル一覧（Spike なので、報告後に revert してよいかも明記）
```

### 9.2 委譲プロンプト案 — Wave 1 / T1〜T4（nest-developer, model: opus）

```
まず /Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md を読み従うこと。

【目的】AdMob リワード広告「動画視聴で30日間だけ名義枠+1」のサーバー側を実装する。
iOS はこの契約に合わせて別タスクで実装されるため、契約からの逸脱は不可。

【対象】/Users/yuyamorishita/オタ活アプリ/apps/api

【契約の正（逸脱禁止・実装前に全文を読むこと）】
docs/plans/admob-integration/api-contract-delta.md
要件は docs/plans/admob-integration/requirements.md §F6。

【やること（この順で。テスト先行 Red→Green）】
1. T1: prisma/schema.prisma に Entitlement の 2 カラム追加 + RewardedAdClaim 新設 + User リレーション。
   cd apps/api && npx prisma db push（必ず apps/api で実行 — BE-5）
2. T2: entitlements.service.ts に rewardedViews() を追加（JST 月境界の遅延リセット）。
   me.service.ts の MeEntitlementView に 3 キー追加、DELETE /v1/me の削除順に rewardedAdClaim を追加
3. T3: src/rewards/ を新設し POST /v1/rewards/claims と GET /v1/rewards/claims/:claim_id。
   ErrorCode に PLAN_LIMIT_REWARDED_VIEWS / REWARD_SLOT_ACTIVE / REWARD_NOT_APPLICABLE を追加
4. T4: GET /v1/webhooks/admob-ssv（@Public()）。署名検証 + 鍵キャッシュ + 付与トランザクション

【受入基準 → 先に失敗するテストを書く】
docs/plans/admob-integration/plan.md §8.1 の AC-AD-01〜19。AC-ID をテスト名に含めること。

【従うべき既存例】
- 公開 Webhook の形: apps/api/src/billing/billing.controller.ts:1-25
- 「不正でないが処理不要」は warn ログ + 200 no-op: apps/api/src/billing/billing.service.ts:38-52
- ボーナス枠の既存判定（触らずに再利用する）: apps/api/src/entitlements/entitlements.service.ts:87-91
- 上限超過エラーの出し方: apps/api/src/identities/identities.service.ts:63-70

【制約・やらないこと】
- Controller / UseCase から Prisma を直接叩かない（BE-3 / ADR-009）
- bonus_identity_slots は「+= 1」ではなく「= 1」（同時1枠。docs/07:415）
- 署名検証は @Query() のパース結果から再構築しない。@Req() の req.originalUrl から
  "&signature=" の直前までを切り出す（api-contract-delta.md §5。ここを間違えると必ず検証が落ちる）
- P2002 を INTERNAL 500 に落とさない。リプレイとして 200 no-op に写す（BE-6）
- 他ユーザーの claim は 403 ではなく 404（BE-4・既存モジュールと同じ）
- .env / apps/api/.env.example は触らない（ユーザー対応）
- iOS 側は触らない

【完了条件】
cd apps/api && npx tsc --noEmit && npm test && npm run build がすべて緑

【報告フォーマット】日本語で ①変更ファイル一覧（file:line）②実行した検証コマンドと結果（テスト件数）
③契約と実装が食い違った箇所があれば明記 ④残課題
```

### 9.3 委譲プロンプト案 — Wave 1' / T5（swift-developer）

```
まず /Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md を読み従うこと。

【目的】広告の表示可否ロジックを Domain の純粋型として実装する。SDK に依存させないことで
XCTest による機械検証を可能にする（.claude/rules/01-aidlc.md の iOS 例外条項）。

【対象】/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain

【やること】
1. Sources/Domain/Ads/AdPlacement.swift
   許可された 5 面のみを case に持つ enum（homeBottom / identitiesBottom / applicationsInline /
   tourTableBetween / identityDetailBottom）。**禁止面の case を作らないこと**
   （docs/07:407「フラグで消せる設計にしない」を型で担保する。理由を doc comment に書く）
2. Sources/Domain/Ads/AdGatekeeper.swift
   docs/plans/admob-integration/requirements.md F4-1〜F4-6 の 6 条件を判定する純粋 struct
3. Sources/Domain/Stores/AdsStore.swift
   @Observable。セッションのインプレッション数・直近表示 placement・起動時刻・
   ステータス変更時刻・オンライン状態を保持し、AdGatekeeper に渡す

【受入基準 → 先に失敗するテストを書く】
docs/plans/admob-integration/plan.md §8.2 の AC-AD-20〜28。AC-ID をテスト名に含める。
Tests/DomainTests/AdGatekeeperTests.swift に置く。

【従うべき既存例】
- @Observable Store の書き方: meigicho/Packages/Domain/Sources/Domain/Stores/PurchasesStore.swift
- Entitlement の plan 判定: meigicho/Packages/Domain/Sources/Domain/Models/AccountModels.swift:94-122

【制約・やらないこと】
- Domain に GoogleMobileAds / SwiftUI / SwiftData を import しない（IOS-5・docs/05）
- AccountModels.swift は触らない（別タスク T6 が所有）
- AdSlot（View）は作らない（DesignSystem の別タスク T8 が所有）

【完了条件】cd meigicho/Packages/Domain && swift test が全緑

【報告フォーマット】日本語で ①追加ファイル（file:line）②テスト件数と結果 ③残課題
```

### 9.4 code-reviewer への引き渡し（T13・**別セッション**）

```
【対象差分】main...HEAD（admob-integration の全変更）
【計画の正】docs/plans/admob-integration/requirements.md / api-contract-delta.md / plan.md
【保存先】docs/plans/admob-integration/review.md

【重点観点】
1. 契約 3 層の整合: schema.prisma ↔ NestJS dto/controller ↔ iOS Network DTO / Domain（IOS-2）
2. BE-4: GET /v1/rewards/claims/:id の他ユーザーアクセスが 404 か。SSV が @Public() で
   署名検証を確実に通しているか
3. BE-6: SSV の P2002 が 500 になっていないか
4. D3 の型ガード: AdPlacement に禁止面の case が混ざっていないか。
   requirements.md F3 の 8 画面に AdSlot が無いか（実際に grep すること）
5. docs/07 §7.6 のデザイン規約（「広告」ラベル・14px 下限・推しカラー非適用・
   プレースホルダ高さ固定）が実装されているか
6. docs/08 §2.8: NSUserTrackingUsageDescription が Info.plist に入っていないこと（重要）
7. IOS-5: Features が GoogleMobileAds / Network を直接参照していないこと

【スコープ外（指摘不要）】
identities.locked_at による Free 復帰時の名義縮退（docs/07 §9.5・別計画）、
自前 analytics_events、統計画面、ATT/UMP、RevenueCat 再有効化
```

---

## 10. 残課題・ユーザー対応が必要な項目

### 10.1 ユーザー対応が必要（エージェントは触れない / 用意できない）

| # | 内容 | 必要タイミング |
|---|---|---|
| U1 | AdMob アカウント作成 + アプリ登録（`GADApplicationIdentifier`） | 実配信前 |
| U2 | 広告ユニット ID 6 本の発行（`docs/07:877` の命名） | 実配信前 |
| U3 | AdMob 管理画面で SSV コールバック URL を設定（`https://<cloud-run>/v1/webhooks/admob-ssv`） | リワード実配信前 |
| U4 | 広告カテゴリブロック（ギャンブル / 出会い系 / 投資・仮想通貨 / 美容医療 / **チケット売買・転売**）+ コンテンツレーティング `G` | 実配信前（`docs/08:545` / R14） |
| U5 | 自動再生動画・点滅フォーマットの除外設定 | 実配信前 |
| U6 | `SKAdNetworkItems` を Info.plist に追記（Google 提供リスト） | 審査提出前 |
| U7 | `apps/api/.env.example` に `ADMOB_SSV_ENABLED` / `ADMOB_SSV_KEYS_URL` を追記（deny 設定でエージェントが書けない） | BE 実装完了時 |
| U8 | プライバシーポリシーに AdMob の記載があることを確認（`docs/08:450` で既に列挙済み。文面の最終確認のみ） | 審査提出前 |

### 10.2 本計画のスコープ外（別途起票が必要）

| # | 内容 | 参照 |
|---|---|---|
| S1 | `identities.locked_at` — Free 復帰 / ボーナス失効時に 4 件目を「閲覧のみ」にする縮退。**リワードの 30 日が切れたときの正しい挙動（`docs/07:431`・F6-9）はこれが無いと実現しない**。現状は「新規追加だけ拒否」に留まる | `docs/07 §9.5`、roadmap 1-10 |
| S2 | ボーナス失効 3 日前のローカル通知（F6-8）。既存 `NotificationPlanner`（`docs/plans/STATUS.md` §5）に種別を追加する小規模タスク。S1 と同時が自然 | `docs/07:432` |
| S3 | RevenueCat の再有効化（T0b でリネームした場合に可能になる） | `docs/plans/STATUS.md` §3 |
| S4 | 自前 `analytics_events` と課金ファネル計測 | `docs/07 §10.1` |
| S5 | ATT / UMP 導入（Phase 2 の A/B 項目） | `docs/07:467`、`docs/08 §2.8` |
| S6 | リリース後 7 日の実測 eCPM / RPM による広告枠の撤去判断 | `docs/07:468, 881` |

### 10.3 リスク

| # | リスク | 緩和 |
|---|---|---|
| R1 | `Network` 名衝突で iOS 全タスクが止まる | T0 Spike を最優先。T0b のリネーム手順を先に用意 |
| R2 | 起動時間の悪化（`docs/09` T7） | `Task.detached(.utility)` + 起動 30 秒の要求抑止 + AC-AD-37 の計測 |
| R3 | SSV の署名検証が通らない（raw query の扱い） | D7 を契約に明記 + AC-AD-12 で回帰防止 |
| R4 | ネイティブ広告のカスタムレイアウトが DADS 規約を満たせない | Stage 分割（Q4 案 B）でバナー先行。ネイティブは実 ID 取得後に実機で確認 |
| R5 | 広告禁止領域が将来の改修で崩れる | D3 の型ガード + AC-AD-27 のソース走査テスト |
