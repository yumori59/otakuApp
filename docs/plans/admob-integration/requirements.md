# requirements — admob-integration

対象: `docs/09-roadmap.md` Phase 1 の **1-11「AdMob 組み込み」**、および **1-10「リワード広告での名義枠一時解放」の広告部分**。

**本書は新規の要件定義ではなく、既に確定している設計（`docs/07 §7` / `docs/08 §2.8` / `docs/05 §7`）を実装可能な単位へ翻訳したもの。**
設計そのものを変更する提案は行わず、docs 間で矛盾している箇所のみ `questions-requirements.md` に上げている（Q2 / Q3 / Q7）。

---

## 1. 現状把握（検証済み）

### 1.1 広告側 — ゼロから

| 層 | 現状 | 根拠 |
|---|---|---|
| iOS SDK | Google Mobile Ads SDK の依存は無い | `meigicho/project.yml` の `packages:` に無し |
| iOS UI | `AdSlot` / `BannerAdView` / `AdPlacement` は**存在しない**（`docs/05:851-882` はコード例であって実装ではない） | `grep -rn "AdSlot\|GADMobileAds" meigicho` → ヒット 0（コメント 1 件のみ） |
| iOS 導線 | ペイウォールの第3導線は**プレースホルダ** | `meigicho/Packages/Features/Sources/Features/Monetization/PaywallView.swift:49-52` — タップすると `"リワード広告は準備中です"` を表示するだけ |
| BE | リワード関連エンドポイント無し | `docs/04-api.md` に `reward` の記述 0 件、`apps/api/src` にモジュール無し |

### 1.2 ボーナス枠は **3 層とも既に配線済み**（重要 — 重複実装しないこと）

`docs/07 §7.5` の DDL 案のうち **`bonus_identity_slots` / `bonus_expires_at` は既に存在し、名義上限の判定まで通っている**。

| 層 | 実体 |
|---|---|
| DB | `apps/api/prisma/schema.prisma:93-94` — `bonusIdentitySlots Int @default(0)` / `bonusExpiresAt DateTime?` |
| BE 判定 | `apps/api/src/entitlements/entitlements.service.ts:87-91` — `bonus_expires_at` が未来のときだけ加算（期限ちょうどは無効）。`identityLimit()` = plus/grace なら `null`（無制限）、free なら `3 + bonus` |
| BE 適用 | `apps/api/src/identities/identities.service.ts:63-70, 146-154` — 超過時 `PLAN_LIMIT_IDENTITY` 403 |
| BE 露出 | `apps/api/src/me/me.service.ts:35-36, 238-240` — `GET /v1/me` の `entitlement.bonus_identity_slots` / `bonus_expires_at` |
| iOS DTO | `meigicho/Packages/Network/Sources/Network/DTO/MeDTO.swift:63-64, 72-73, 134-135` |
| iOS Domain | `meigicho/Packages/Domain/Sources/Domain/Models/AccountModels.swift:99-100` |

**ギャップ**: `rewarded_views_month` / `rewarded_views_reset_at`（月2回上限のサーバー判定）と、**付与を起こす経路そのもの（SSV）**が無い。

### 1.3 既存の踏襲対象パターン

| 用途 | 既存例 |
|---|---|
| 公開 Webhook（Guard 除外 + 検証 + no-op 方針） | `apps/api/src/billing/billing.controller.ts:1-25`（`@Public()` + `assertAuthorized`）、`apps/api/src/billing/billing.service.ts:23-52`（未知ユーザーは warn ログ + 200 no-op） |
| SDK 未設定時のフォールバック | `meigicho/App/Purchases/PurchasesServiceFactory.swift` + `DisabledPurchasesService.swift`（`REVENUECAT_API_KEY` 空なら無効実装を返す） |
| SDK を `#if canImport` で封鎖 | `meigicho/App/Purchases/RevenueCatPurchasesService.swift` |
| エラー envelope / コード | `docs/plans/backend-domain-modules/api-contract.md §0` |

### 1.4 ブロッカー: 自作 `Network` パッケージ名の衝突

`meigicho/Packages/Network` が Apple の `Network.framework` とモジュール名衝突を起こし、**RevenueCat SDK は現在無効化されている**（`docs/plans/STATUS.md` §3、`meigicho/project.yml:26-30`）。Google Mobile Ads SDK でも同種の事故が起きうるため、**着手前に Spike で実測する**（`plan.md` T0 / `questions-requirements.md` Q1）。

---

## 2. 機能要件

### F1. AdMob SDK の導入と初期化

| ID | 要件 | 出典 |
|---|---|---|
| F1-1 | Google Mobile Ads SDK を SPM で導入する。Privacy Manifest 付きの**署名済みバージョン**を使う | `docs/08:552` |
| F1-2 | `GADMobileAds.start` は `Task.detached(priority: .utility)` で実行し、初回描画をブロックしない | `docs/05:952`、`docs/09:534`（T7） |
| F1-3 | **起動から 30 秒間は広告リクエストを行わない** | `docs/07:451` |
| F1-4 | 全リクエストに `npa=1`（非パーソナライズ）を `GADExtras` で設定する | `docs/08:511` |
| F1-5 | `NSUserTrackingUsageDescription` を Info.plist に**入れない**。ATT プロンプトを出さない。UMP も入れない | `docs/08:497, 511`（※ Q2 の確定待ち） |
| F1-6 | 広告ユニット ID が未設定（空文字）のときは SDK を初期化せず、広告枠を一切描画しない | 既存 `PurchasesServiceFactory` パターンの踏襲 |
| F1-7 | 起動 TTI p95 < 2 秒を維持する（劣化していないことを手動計測で確認） | `docs/09:534`（T7） |

### F2. 広告フォーマットと配置

**使うフォーマット**: インライン・アダプティブバナー / ネイティブ（小） / リワード動画。
**使わない**: アンカーバナー / インタースティシャル / リワード・インタースティシャル / アプリ起動時広告（`docs/07:373-378`）。

| ID | 画面 | 位置 | フォーマット | 上限 | AdMob ユニット名 |
|---|---|---|---|---|---|
| F2-1 | ホーム | 「当落発表待ちの申込」リストの**後**、画面最下部 | ネイティブ（小） | 1枚 | `ios_home_native_bottom` |
| F2-2 | 名義一覧 | `card-list` の**後**、画面最下部 | インラインバナー | 1枚 | `ios_identities_banner_bottom` |
| F2-3 | 申込一覧（リスト） | 5件目の後、以降10件ごと | ネイティブ（`ticket-row` と同じカード形状） | 1画面あたり2枚 | `ios_applications_native_inline` |
| F2-4 | 申込一覧（ツアー表） | `tour-group` と `tour-group` の**間**（表の内側には絶対に入れない） | インラインバナー | 全体で1枚 | `ios_tourtable_banner_between` |
| F2-5 | 名義詳細 | 「申込履歴」リストの**後**、画面最下部 | インラインバナー | 1枚 | `ios_identitydetail_banner_bottom` |
| F2-6 | ペイウォール（第3導線） | 名義上限トリガー時のみ | リワード動画 | — | `ios_rewarded_identity_slot` |

出典: `docs/07:382-392, 877`。**ホームで `stat-row` の直下には置かない**（`docs/07:390`）。

### F3. 広告を絶対に出さない場所（コード構造で担保）

| ID | 場所 |
|---|---|
| F3-1 | 当落ステータスを切り替える瞬間（`status-changer`） |
| F3-2 | 申込詳細のヒーロー部（`ticket-hero`） |
| F3-3 | **申込詳細の画面全体**（最下部含め広告ゼロ） |
| F3-4 | 入力フォーム全画面（名義追加 / 会員情報追加 / 申込追加、およびすべての編集フォーム） |
| F3-5 | 共有プレビュー |
| F3-6 | 共有ボード（`SharedBoard`） |
| F3-7 | 通知タップからの初回画面 |
| F3-8 | 会員番号が表示される領域の隣（`membership-card` / `membership-no`） |

出典: `docs/07:396-405`。

**F3-9【最重要】この禁止領域は feature flag ではなく型で担保する。** `docs/07:407` が明示している。
実装方針（`plan.md` §4 D3）:
- `AdPlacement` enum に**許可された 6 面のみを列挙する**。禁止面は case として**存在させない** → 禁止画面では `AdSlot` を構築する引数が作れない。
- 加えて、禁止画面のソースファイルに `AdSlot` の文字列が出現しないことを検査するテストを置く（新 case が追加されても弾ける）。

※ `docs/05:864-872` のコード例は禁止面も case に持ち `allowsAds: false` を返す設計だが、これは `allowsAds` を書き換えるだけで広告を出せてしまい `docs/07:407` の意図（「将来の収益改善圧で必ず戻される」を防ぐ）を満たさない。**より強い型ガードとして許可面のみ列挙する形を採用する**（設計の変更ではなく強化）。

### F4. 表示頻度・クールダウン

| ID | 要件 | 出典 |
|---|---|---|
| F4-1 | 1セッション最大 3 インプレッション（セッション定義は Q10） | `docs/07:451` |
| F4-2 | 起動から 30 秒間はリクエストしない | `docs/07:451` |
| F4-3 | 同一画面で連続 2 枚を出さない | `docs/07:451` |
| F4-4 | オフライン時は枠自体を出さない（空枠を残さない） | `docs/07:451` |
| F4-5 | **ステータス変更後 60 秒間はアプリ内の全広告リクエストを止める** | `docs/05:885-886` |
| F4-6 | Plus（`plan == .plus`、grace 中含む）は広告を一切描画しない（空の高さも取らない） | `docs/07:66`、`docs/05:874` |

**F4-7**: 上記 6 条件の判定は **`Domain` パッケージの純粋型 `AdGatekeeper` に集約する**（SDK 非依存 → XCTest で検証可能）。`.claude/rules/01-aidlc.md`「iOS の振る舞いロジックは Domain / Core の純粋関数か BE に寄せる」に従う。

### F5. デザイン規約（DADS 準拠）

| ID | 要件 | 出典 |
|---|---|---|
| F5-1 | カード左上に日本語の **`広告`** ラベル（`Sponsored` / `PR` は使わない）。`.tag` と同じスタイル | `docs/07:443` |
| F5-2 | 既存カードの形状トークンを流用（`--r-md` / 1px `--border` / `--surface` / padding 14px、`ticket-row` と同じ） | `docs/07:444` |
| F5-3 | **推しカラーテーマを広告に適用しない**（`--primary` を使わず常に `--gray-*`） | `docs/07:445` |
| F5-4 | 広告 CTA は枠線ボタン。`btn-primary-block`（塗り）と見分けがつくこと | `docs/07:446` |
| F5-5 | 見出し 16px / 本文 14px。**14px 未満を使わない**。AdMob のネイティブテンプレートは使わず**カスタムレイアウト**で実装 | `docs/07:447` |
| F5-6 | プレースホルダ高さを事前固定（読み込み完了でリストが飛ばない）。画像取得失敗時はテキストのみで表示し空枠を残さない | `docs/07:448` |

### F6. リワード広告「動画視聴で 30 日間だけ名義枠 +1」

| ID | 要件 | 出典 |
|---|---|---|
| F6-1 | 報酬は名義上限 **+1**（3 → 4）、有効期間は視聴完了から **30 日** | `docs/07:415` |
| F6-2 | 同時に持てるボーナス枠は **1 枠まで**（※ Q3 の確定待ち） | `docs/07:415` |
| F6-3 | 再視聴による延長は **残り 7 日以内**になってから可 | `docs/07:415` |
| F6-4 | **月間視聴上限は 2 回**。判定はサーバー側 `entitlements`（クライアント値を信用しない） | `docs/07:415, 435` |
| F6-5 | Plus 契約中は導線を表示しない。サーバーも受け付けない | `docs/07:415` |
| F6-6 | 付与は AdMob の **SSV（Server-Side Verification）で署名検証してから** | `docs/07:435`、`docs/08:645, 785` |
| F6-7 | **1 日 3 回以上の視聴試行はログに記録**し異常検知の対象にする | `docs/07:435` |
| F6-8 | 期限 3 日前にローカル通知（「『〜』の追加枠が3日後に終わります。Plus にすると、そのまま使い続けられます。」） | `docs/07:432` |
| F6-9 | 30 日後に上限に戻るとき、4 件目の名義は**消えず閲覧のみになる**（`docs/07 §9.5` と同じ挙動） | `docs/07:431` |

**F6-9 の扱い**: 名義の `locked` 状態（`identities.locked_at`）は `docs/07 §9.5` の Plus 解約時縮退と共通の仕組みであり、**本計画のスコープ外**（未実装。roadmap 1-10 の別項目）。本計画では「上限を超えた状態で新規追加のみ拒否される」既存挙動（`identities.service.ts:63-70`）に留め、`plan.md` §9 に残課題として明記する。

### F7. 計測

| ID | 要件 | 出典 |
|---|---|---|
| F7-1 | 広告ユニットを**画面ごとに分けて作成**する（F2 の 6 本） | `docs/07:875-877` |
| F7-2 | `rewarded_ad_shown` / `rewarded_ad_completed`（`placement` パラメータ付き）を記録できる状態にする | `docs/07:857` |

**F7 の扱い**: 自前 `analytics_events` テーブルは未実装（`docs/07:902`）。本計画では **AdMob 管理画面のレポート（無料・`docs/07:901`）で足りる範囲に留め**、自前イベント基盤は起票しない。F7-2 は BE の `rewarded_ad_claims` 行（作成 = shown 相当、granted = completed 相当）で代替できることを確認済み。

---

## 3. 非機能要件

| ID | 要件 | 検証方法 |
|---|---|---|
| N1 | 起動 TTI p95 < 2 秒（AdMob 導入前後で劣化しない） | 手動計測（`plan.md` §7） |
| N2 | `xcodebuild` BUILD SUCCEEDED（`CLAUDE.md` 検証ゲート） | 機械ゲート |
| N3 | `cd apps/api && npx tsc --noEmit && npm test && npm run build` 全緑 | 機械ゲート |
| N4 | 既存 iOS パッケージテスト（Core / Domain / Network）が全緑を維持 | `swift test` |
| N5 | 広告関連の秘密情報を持たない（SSV は Google 公開鍵検証のみ・Q6） | レビュー観点 |
| N6 | 広告ユニット ID 未設定でもアプリが正常動作する（クラッシュしない・空枠を出さない） | 手動確認 |
| N7 | App Privacy の「トラッキング」を**なし**で申告できる状態を保つ | `docs/08:456, 483` / レビュー観点 |

---

## 4. 制約

| ID | 制約 |
|---|---|
| C1 | **BE レイヤは Controller → UseCase → Service → Prisma**。Controller / UseCase から Prisma を直接叩かない（BE-3 / ADR-009） |
| C2 | **ID は UUID**（クライアント発行 v7 前提）。`claim_id` も UUID（BE-1） |
| C3 | **iOS の `Features` は `Network` / `DataStore` / 広告 SDK を直接参照しない**。Composition Root で注入（IOS-5） |
| C4 | **`Domain` に SDK 依存を持ち込まない**（`AdGatekeeper` / `AdPlacement` は純粋型） |
| C5 | prisma コマンドは必ず `apps/api/` で実行（BE-5） |
| C6 | 公開エンドポイント（SSV）は `@Public()` + 署名検証。認証必須エンドポイント（claims）は Guard + `userId` スコープ（BE-4） |
| C7 | Prisma 例外（P2002 / P2025）を INTERNAL 500 に落とさない（BE-6）。SSV の `transaction_id` 一意制約違反は**リプレイとして 200 no-op** に写す |
| C8 | `apps/api/.env.example` はエージェントが書けない（deny 設定）。ユーザー対応 |
| C9 | `docs/07` / `docs/09` の設計方針を勝手に変更しない。矛盾は `questions-requirements.md` へ |
| C10 | インタースティシャルを実装しない（`docs/07:409-411`。将来の誘惑に対してもコードを置かない） |

---

## 5. スコープ外（明記）

| # | 項目 | 理由 / 参照 |
|---|---|---|
| S1 | `identities.locked_at` による Free 復帰時の名義縮退 | `docs/07 §9.5` の別機能。roadmap 1-10 の残り部分 |
| S2 | 自前 `analytics_events` テーブルと課金ファネル計測 | `docs/07 §10.1`。AdMob レポートで代替（F7） |
| S3 | ATT / UMP の実装 | Q2 で `docs/08 §2.8` を正とする前提。将来 Phase 2 の A/B 項目（`docs/07:467`） |
| S4 | 統計画面（ソフトウォール） | roadmap 1-5。`docs/plans/STATUS.md` §7 |
| S5 | RevenueCat の再有効化・本番課金の有効化 | 別作業（Q1 B を選んだ場合のみ副次的に可能になる） |
| S6 | eCPM / RPM の実測と広告枠の撤去判断（`docs/07:881`） | リリース後の運用 |
| S7 | 広告カテゴリブロック等の AdMob 管理画面設定 | ユーザー対応（Q5 U4 / U5） |

---

## 6. 未確定事項（実装着手前に確定が必要）

| Q | 内容 | ブロックするタスク |
|---|---|---|
| Q1 | `Network` パッケージ名衝突とリネームの是非 | iOS 全タスク（T0 の Spike 結果次第） |
| Q2 | ATT を実装するか（docs 矛盾） | T-IOS-3（SDK 初期化）、docs 修正タスク |
| Q3 | ボーナス同時枠 1 か 2 か（docs 矛盾） | T-BE-2（付与ロジック） |
| Q4 | 段階リリースするか（工数超過） | Wave 構成全体 |
| Q5 | AdMob 実 ID の用意時期 | 実配信のみ（実装は進行可） |
| Q9 | SSV のローカル検証手段 | T-BE-3 の検証手順 |

Q6 / Q7 / Q8 / Q10 は planner の既定を採用済み（`questions-requirements.md` 参照）。
