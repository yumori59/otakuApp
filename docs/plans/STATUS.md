# STATUS — 開発進捗（横断サマリ）

**このファイルの目的**: 複数セッション・複数サブエージェントが現在の全体進捗を素早く把握するための単一の参照点。
各計画の詳細は `docs/plans/<feature>/` 配下（`requirements.md` / `api-contract*.md` / `plan.md` / `review.md`）を正とする。
本ファイルは索引であり、内容が古くなったら都度更新する（作業開始・完了のたびに反映すること）。

最終更新: 2026-08-09

---

## 方針決定（横断）

| 日付 | 決定 | 影響 |
|---|---|---|
| 2026-08-05 | **アプリ不要の独立共有 Web（Next.js / Cloudflare Pages）は作らない** | 閲覧・編集の正は iOS `SharedBoard` + `GET/PATCH /public/shares/:token`。`docs/00`〜`09`・本 STATUS を更新。roadmap 1-7 は廃止（工数 0）。Universal Links は任意の後続 |
| 2026-08-07 | **共有はアカウント招待制に完全移行する。公開トークン経路は廃止** | `GET/PATCH /public/shares/:token` を削除し、受け取りは Bearer 必須の受信箱（`/v1/shares/received/*`）に一本化。`share_recipients` が ACL の実体。`docs/10` §3 の「Phase 2 で再決定」に対する決定。計画は `docs/plans/share-account-invites/`。**副作用: `docs/09` の KPI「共有リンク経由の新規インストール比率 ≥ 10%」は達成不能になるため要再設定（未起票）** |
| 2026-08-08 | 共有アカウント招待制化（BE/iOS）完了。レビューで重大1件（受信箱の未読が消えないバグ）検出→修正→重大ゼロ。main マージ済み | BE 884テスト・iOS Domain 207/Network 165全緑。§9 参照 |
| 2026-08-09 | 全`review.md`を横断調査し、過去レビューで発見済みだが「重大ゼロ」基準未達のため未修正のまま残っていたバグ3件を修正。main マージ済み（`docs/plans/bugfix-batch1/review.md`） | ①ログアウト直後のトークンrefresh競合でユーザーが黙って復帰 ②アカウント削除シートがApple再認可の無応答で操作不能に固定 ③受信箱の未読フラグが他の招待者の閲覧で誤って戻る。**レビューで各修正自体が生んだ新たな重大バグ2件も発見・修正**（サインイン直後のサイレントログアウト／「閉じる」後もアカウント削除が裏で進行）。`feedback_review_patterns.md`にIOS-13追記 |

---

## 全体像

```
BE: ドメイン + 認証拡張 + home/stats/sync/billing（2026-08-05 完了）
iOS: ネットワーク接続・home/summary・ペイウォール・stats/identities 接続（2026-08-05）
同期エンジン（`docs/plans/ios-sync-engine/`）・AdMob（Phase 1-11 Stage1）ともT0-T5/T13完了
共有: 独立 Web ビューは対象外。アプリ内 SharedBoard が正
共有の認可: **アカウント招待制へ完全移行済み（レビュー重大ゼロ・main マージ済み — `docs/plans/share-account-invites/`）**
            公開経路 `/public/shares/:token` は削除済み。受け取りはアプリ内受信箱（Bearer必須）に一本化
```

---

## 1. BE — `docs/plans/backend-domain-modules/`（完了）

Controller→UseCase→Service→Prisma の全ドメインモジュール新規実装。

| モジュール | 状態 |
|---|---|
| auth（Sign in with Apple + JWT + refresh回転） | ✅ |
| me（プロフィール） | ✅ |
| identities / memberships | ✅ |
| tours / events / applications（find-or-create TX） | ✅ |
| shares / public（読み取り専用共有 + マスキング） | ✅ |

- レビュー: 初回で重大2件検出 → 修正 → 再レビューで**重大ゼロ**（`review.md`）
- 検証: `cd apps/api && npx tsc --noEmit && npm test && npm run build` 全緑
- 契約の正: `api-contract.md`

## 2. BE — `docs/plans/backend-auth-and-shares-extension/`（完了）

ユーザー判断により追加された拡張（App Store Guideline 4.8対応 + 共同編集）。

| 機能 | 状態 |
|---|---|
| Google Sign-In（`POST /v1/auth/google`） | ✅ |
| メール+パスワード（register/login/password/reset-request/reset） | ✅ |
| 共有write権限（`permission:"write"`、Free=公演3件まで/Plus無制限） | ✅ |
| `PATCH /public/shares/:token/items/:item_key`（共有先が状況・座席を編集） | ✅ |

- レビュー: 初回で重大ゼロ・中4件 → 2件修正（ログ漏洩リスク・コメント誤り）
- 検証: `cd apps/api && npx tsc --noEmit && npm test && npm run build` 全緑（**685テスト**）
- 契約の正: `api-contract-delta.md`（`backend-domain-modules/api-contract.md`への追記差分）

## 2b. BE — 集約・同期・課金 Webhook（2026-08-05 完了）

| 機能 | 状態 |
|---|---|
| `GET /v1/home/summary` | ✅ |
| `GET /v1/stats/identities` | ✅ |
| `POST /v1/sync/pull` / `push` | ✅ |
| `POST /v1/webhooks/revenuecat` | ✅ |

- 検証: `cd apps/api && npx tsc --noEmit && npm test && npm run build` 全緑（**765テスト**）

### BE残課題（ユーザー対応が必要。エージェントは秘密ファイル保護のため触れない）

`apps/api/.env.example` に以下5キーを追記:
```
GOOGLE_CLIENT_IDS=
GOOGLE_ISSUER=
GOOGLE_JWKS_URL=https://www.googleapis.com/oauth2/v3/certs
RESEND_API_KEY=
RESEND_FROM_EMAIL=
```
ローカルDBは `make db-only && cd apps/api && npx prisma db push` 済み（Docker起動済み前提）。

## 3. iOS — `docs/plans/ios-network-integration/`（完了）

契約の正: `contract-mapping.md`（iOS側DTO/Domain型の正）+ 上記2つのBE契約。

| Wave | Task | 内容 | 状態 |
|---|---|---|---|
| 0 | T0 | Network新設・Domain型再構成・Store分割・Features機械分割 | ✅ |
| 1 | T1 | 認証基盤（Keychain・401自動refresh）+ Apple + Google | ✅ |
| 2 | T1b | メール+パスワード5本 + `GET/PATCH /v1/me` | ✅ |
| 2 | T2 | identities + memberships 接続 | ✅ |
| 2 | T3 | applications + tours/events 接続 | ✅ |
| — | T1c | **ゲスト（未ログイン）閲覧モード**（新規・ユーザー追加要件） | ✅ |
| 3 | T4 | 共有リンク管理（オーナー側） | ✅ |
| 3 | T4b | 共有ボード（受け取り側・`PublicApiClient`経由） | ✅ |
| 4 | T5 | code-reviewer（別セッション） | ✅ **重大ゼロ**（初回: 重大1・中5 → 修正 → 再レビューで重大ゼロ） |

**最終状態**: `xcodebuild` BUILD SUCCEEDED / Core 17・Domain 138・Network 139 = **294テスト全緑**。
残存軽微事項（対応不要・記録のみ）は `docs/plans/ios-network-integration/review.md` 参照（ログアウト直後の極小レースウィンドウ等）。

Wave 2完了時点で全体ゲート確認済み: `xcodebuild` BUILD SUCCEEDED / Core 17・Domain 91・Network 92 = **200テスト全緑**。
`AppEnvironment.swift` の Remote切替配線（identityRepository/membershipRepository）はオーケストレーターが集約して実施済み。

### 追加要件: ゲスト（未ログイン）閲覧モード
ユーザー要望により、起動時の全画面ログインゲート（`AuthGateView`、Q5の当初決定）を廃止し、未ログインでも閲覧できるように変更中。
範囲は「閲覧・お試し程度、保存は求めない」（`docs/plans/ios-network-integration/questions-requirements.md` Q5 参照）。
`docs/08-compliance-risk.md:523`（Guideline 5.1.1(v)、サインイン必須化の禁止）にも合致。

### iOS既知の未検証事項（実機・実サービス依存）
- Sign in with Apple: Capability/署名未設定のため実機/シミュレータでの実ログイン未検証（ユーザーによる証明書設定待ち）
- Google Sign-In: OAuthクライアントID未取得のため未検証。BE `GOOGLE_CLIENT_IDS` とiOS `project.yml` の `GOOGLE_IOS_CLIENT_ID` に同じ値が必要
- ~~APIコンテナが古いビルドのまま~~ → **解消済み**。`docker compose build api && make up` 実施済み。`POST /v1/auth/register`(201)・`POST /v1/auth/google`(不正トークンで401)を実測確認
- BE手動検証中に作成されたテストユーザー（`t3verify-*@example.com`等）がローカルDBに残存。破壊操作のため未削除、必要なら別途対応

### RevenueCat（課金SDK）の一時無効化
別セッションで`meigicho/App/Purchases/**`・`Domain/Purchases/**`にRevenueCat統合が追加されていたが、
自作`Network`パッケージ名とApple標準`Network.framework`が衝突しクリーンビルドが失敗する状態だった（アカウント削除機能レビューで発覚）。
ユーザー了承のもと一時無効化: `project.yml`のRevenueCatパッケージ依存をコメントアウトし、
`RevenueCatPurchasesService.swift`を`#if canImport(RevenueCat)`で囲み、`PurchasesServiceFactory`は常に`DisabledPurchasesService`を返す。
実装コード自体は削除していないため、`project.yml`のコメントを外せば再有効化できる。
`Package.resolved`を再生成した完全クリーンビルドで復旧を確認済み（Core 17 + Domain 162 + Network 148 = 327テスト全緑）。

### 共通検証ゲート
```bash
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
cd meigicho/Packages/Core && swift test
cd meigicho/Packages/Domain && swift test
cd meigicho/Packages/Networking && swift test
```

---

## 4. account-deletion — `docs/plans/account-deletion/`（実装済み）

App Store Review Guideline 2.5 対応。`DELETE /v1/me`（BE）+ アカウント設定からの削除 UI（iOS）。

| 機能 | 状態 |
|---|---|
| BE `DELETE /v1/me`（順序付き物理削除・本人確認） | ✅ |
| BE Apple トークン失効（ベストエフォート） | ✅ |
| iOS `AccountDeleteView` + Domain/Network 配線 | ✅ |
| iOS Apple 再認可（`AppleReauthorization`） | ✅ |
| レビュー: 初回 重大2/中4 → 修正 → 再レビューで**重大ゼロ** | ✅（`review.md`） |
| `docs/04-api.md` に `DELETE /v1/me` 追記 | ✅ |

## 5. ローカル通知・重複申込（2026-08-05 実装）

| 機能 | 状態 |
|---|---|
| `NotificationPlanner`（Domain・64件上限） | ✅ |
| `NotificationScheduler`（App・更新/当落通知） | ✅ |
| 会員情報保存後のプリパーミッション | ✅ |
| 重複申込の注意表示（詳細・ツアー表） | ✅ |
| 通知タップ → identity/application ディープリンク | ✅ |

## 6. 収益化・広告

| 機能 | 状態 | 参照 |
|---|---|---|
| ペイウォール UI（4件目名義・共有2本目・設定から） | ✅ | `docs/07` §4, §6.2 |
| StoreKit 2 + RevenueCat SDK（購入・復元・Offering 表示） | ✅ | `docs/07` §9, `05` §7 |
| BE RevenueCat Webhook → `entitlements` ミラー | ✅ | `docs/07` §9.2, `docs/plans/backend-domain-modules/` |
| 本番課金の有効化（API キー・ASC プロダクト・RC Offering） | ⏳ 手動 | `docs/07` §9.1 |
| AdMob Stage 1（バナー3面: 名義一覧・ツアー表・名義詳細） | ✅ | `docs/plans/admob-integration/`, `docs/07` §7, `09` 1-11 |
| AdMob ネイティブ広告（ホーム最下部・申込一覧5件目以降10件ごと） | ✅ | `docs/plans/admob-integration/` |
| `AdSlot` / 広告禁止画面の型ガード（`AdPlacement`許可5面enum + ソース走査テスト） | ✅ | `docs/plans/admob-integration/plan.md` §4 D3 |
| AdMob リワード広告・SSV | ❌ 対象外（ユーザー判断で不要） | — |

**AdMob Stage 1（2026-08-07 完了）**: `docs/plans/admob-integration/`。Q1〜Q4 はユーザー承認済み（Q1: Network名衝突なし・リネーム不要とSpikeで実証／Q2: docs/08準拠でATTなし・NPA固定／Q3: ボーナス同時枠1枠／Q4: 2段階リリースでStage1先行）。`docs/05`・`docs/09`の矛盾記述は修正済み。
T0(Spike)→T5(Domain: AdPlacement/AdGatekeeper/AdsStore)→T9(App: SDK初期化+バナーRenderer)→T8(DesignSystem: AdSlot/AdCardChrome)→T10(3画面配線)の順で実装。
レビューで重大3件検出→修正→再レビューで**重大ゼロ**（`docs/plans/admob-integration/review.md`）。主な修正: `ADMOB_APP_ID`空文字での起動時クラッシュ（SDKがリンクされているだけで検証に落ちる）、`AdSlot`の`GeometryReader`固定高が後続UIに重なる、no-fill時に空の広告カードが残る。
検証: Domain 183 / DesignSystem 1 / Core 17 / Network 148 テスト全緑、`xcodebuild` BUILD SUCCEEDED、シミュレータ実機起動でクラッシュしないことを確認済み。
`.claude/rules/feedback_review_patterns.md` に IOS-7〜9 追記（SDKリンクのみで落ちる設定／`xcodegen generate`忘れ／`GeometryReader`固定高）。
**AdMobネイティブ広告（2026-08-07 完了）**: ユーザー判断で**リワード広告・SSVはスコープ外**（`bonus_identity_slots`等の付与経路は今後も未実装のまま）。
`AdNativeCard`（DesignSystem・画像/見出し/本文/CTA、画像取得失敗時はテキストのみ）+ `GoogleMobileAdsRenderer.nativeAdView`（`GADAdLoader`）+ ホーム最下部（`homeBottom`）・申込一覧5件目以降10件ごと（`applicationsInline`、1画面上限2枠）に配置。
レビューで重大1件検出→修正→再レビューで**重大ゼロ**（`docs/plans/admob-integration/review.md`）。修正: `UIHostingController`の内容を後から差し替えてもSwiftUIが再計測せず枠をはみ出す不具合（IOS-10として追記）。
**仕様判断（2026-08-07 ユーザー承認）**: 申込一覧の広告は「同一placement連続表示禁止」ルールにより実質1画面1枚のみ表示される（2枚目の同時表示は不可）。Domain側のクールダウン仕様は変更せず、`docs/07`の「1画面2枚」は上限であって最低保証ではないと解釈する。
検証: Domain 188 / DesignSystem 1 テスト全緑、`xcodebuild` BUILD SUCCEEDED。
**AdMob実アカウント未取得のためユーザー対応が必要**: `ADMOB_APP_ID`・広告ユニットID8本（バナー3+ネイティブ2+未使用のリワード枠）は現状空文字（`DisabledAdRenderer`で安全にno-op）。実配信前の項目一覧は `docs/plans/admob-integration/plan.md` §10.1（U1〜U8）。

**iOS 課金の現状**: `PaywallView`・`PurchasesStore`・`RevenueCatPurchasesService` 実装済み。`REVENUECAT_API_KEY` 未設定時は `DisabledPurchasesService` でスタブ動作。4件目名義追加・共有2本目・設定画面からペイウォール表示。`xcodebuild` BUILD SUCCEEDED（Domain 152 / Network 144 tests 全緑）。

## 7. iOS — stats / sync

| 機能 | 状態 | 参照 |
|---|---|---|
| `GET /v1/stats/identities` iOS 接続（Store + 名義一覧/詳細の当選数） | ✅ | `docs/04` §3.5 |
| 統計画面（タブ・グラフ・Plus ソフトウォール） | ❌ | `docs/09` 1-5 / `docs/07` §6.2-C |
| 同期エンジン（DataStore + SyncEngine） | ✅ **T0–T5 全完了**（NWPathMonitorで低データモード実値化・編集後3秒デバウンス・BGAppRefreshTask骨格）。レビューで重大2件（`Network`パッケージ名衝突による増分ビルド破壊／BGTaskの`assumeIsolated`誤ったキューでのクラッシュ）検出→修正→重大ゼロ。**ローカル`Network`パッケージは`Networking`にリネーム済み**（RevenueCat無効化の原因だった衝突も解消） | `docs/plans/ios-sync-engine/` |

---

## 8. インフラ — CI/CD + Terraform IaC（2026-08-07 完了）

`docs/12-app-store-release.md` §6 の「本番デプロイどこから手を付けるか」に対応する形で追加。

| 機能 | 状態 |
|---|---|
| BE自動デプロイ（`main`への`apps/api/**`マージで自動test→build→deploy） | ✅ `.github/workflows/deploy-api.yml` |
| Cloud Run / Artifact Registry / Secret Manager / IAM / WIF のTerraform化 | ✅ `infra/terraform/` |
| インフラ変更の安全弁（apply は `workflow_dispatch` 手動のみ、PRは`plan`のみ自動） | ✅ `terraform-plan.yml` / `terraform-apply.yml` |
| 本番コンテナ起動時の自動 `prisma db push --accept-data-loss` の無効化 | ✅ `apps/api/docker-entrypoint.sh`（`NODE_ENV=production`でスキップ） |

- レビュー: 初回 重大4件（`PORT`がCloud Run予約変数で apply/deploy が必ず失敗する／PR起因のplanが強権限SAで実行されていた／WIFのバインディングがコメントの主張より広い／READMEの初回セットアップ手順が実行不能）→ 修正 → 再レビューで**重大ゼロ**（`infra/terraform/review.md`）
- 検証: `terraform fmt`/`validate`/`plan`（ダミー値・ローカルbackend、36リソース）クリーン、`apps/api` tsc+jest（773テスト）全緑、Dockerで本番/開発分岐を実機確認
- **発見**: `docker-entrypoint.sh`が本番でも起動のたびにDBスキーマを黙って書き換えていた（`--accept-data-loss`付き）。今回のCI/CD着手で偶然発覚し修正
- **未整備（意図的スコープ外）**: DBマイグレーションの自動化（`apps/api/prisma/migrations/`が無くdb pushのみの運用のため）。staging環境（productionのみ）。GCPプロジェクト自体の作成はTerraform管理外（手動、`docs/12-app-store-release.md` §6.2）
- `.claude/rules/feedback_review_patterns.md` に INFRA-1〜5 追記
- 初回セットアップ手順: `infra/terraform/README.md`

## 9. 共有のアカウント招待制化 — `docs/plans/share-account-invites/`（✅ **完了・main マージ済み**）

共有を「トークンURLを知っていれば誰でも閲覧・編集できる」から「**招待されたアカウントだけ**」に変えた。
ユーザー要望（2026-08-07）。`docs/10-mock-delta-2026-07-31.md` §3 が「Phase 2 で再決定」としていた項目の**再決定そのもの**（`docs/10` §3・§4 は決定内容に更新済み）。
Q14 は **14-a**（`SharedBoardLink` / ディープリンク `meigicho://share/<token>` / `redeem` エンドポイントは残す）で実装済み。

### 実装内容（BE・2026-08-08 現在: `apps/api/src` に反映済み）

| 項目 | 内容 |
|---|---|
| 公開経路 | `GET/PATCH /public/shares/:token` を**完全削除**（`apps/api/src/public/` ディレクトリごと消滅。マスキング・ペイロード組み立ての中核は `apps/api/src/shares/board/` へ移設し、中身は変更なし） |
| ACL | `ShareRecipient` モデル新設（`share_recipients` テーブル、`@@unique([shareLinkId, accountId])` + `@@index([userId])`）。`ShareLink.sharedWithAccountIds` は Prisma schema から削除 |
| オーナー側 | `POST /v1/shares`（`shared_with_account_ids` 1〜20件必須）、`GET /v1/shares`（`recipients` 返却）、`POST/DELETE /v1/shares/:id/recipients` |
| 受け取り側 | `apps/api/src/shares/received/`（全 Bearer 必須）: `GET /v1/shares/received`（受信箱一覧）、`GET/PATCH /v1/shares/received/:id`（board 読み取り・書き込み）、`POST /v1/shares/received/redeem`（token→share_id）、`POST/DELETE /v1/shares/received/:id/hide` |
| 判定順序 | PATCH は招待判定（②）を `permission` 判定（③）より前に実装済み（AC-SI-29）。非招待者は token 経路 403 `SHARE_NOT_INVITED` / id 経路 404 `SHARE_INVALID` で出し分け済み（AC-SI-21・AC-SI-26） |
| エラーコード | `SHARE_NOT_INVITED`(403) / `SHARE_RECIPIENT_UNKNOWN`(400) / `SHARE_RECIPIENT_SELF`(400) 追加済み |
| 既存データ移行 | `apps/api/src/shares/migrations/`（全件 `revoked_at` 失効・冪等）実行済み |
| `app.setup.ts` / `app.module.ts` | `GLOBAL_PREFIX_EXCLUDE` から `public/shares/*` の2行削除、`PublicModule` 登録解除。`health`/`readyz`/webhook は維持 |

### 実装内容（iOS・2026-08-08 現在）

| 項目 | 内容 |
|---|---|
| 削除 | `PublicApiClient.swift` / `KeychainSharedBoardTokenStore` 系 / `OpenSharedBoardView.swift`（URL貼り付け画面）。広告禁止画面リスト（`AdSlotForbiddenScreensTests.swift` / `AdGatekeeperTests.swift`）から名指しも除去済み |
| 新規 | `Domain/SharedInboxStore.swift`、`RemoteSharedInboxRepository`、`Features/SharedInbox/`（受信箱画面）、`Domain/Models` の `ShareRecipient` / `SharedInboxItem` |
| 変更 | `SharedBoardStore` / `RemoteSharedBoardRepository` を token 起点 → `shareID` 起点へ、`AppRoute.sharedBoard(token:)` → `.sharedBoard(shareID:)`、`AppEnvironment`（`publicApiClient` 等を削除・`sharedInboxRepository` 注入）、`DeepLinkRouter`（未ログイン時は保留トークンを保持しサインイン後に再試行）、`ShareRecipientsView`（招待必須化・追加削除UI） |
| 保持 | `SharedBoardLink`（token 抽出の純粋パーサ）と `meigicho://share/<token>` ディープリンク受け口（Q14=14-a） |

### レビュー（2026-08-08・別セッション）

初回で**重大1件**検出→修正→再レビューで**重大ゼロ**（`docs/plans/share-account-invites/review.md`）。
重大: `GET /v1/shares/received/:id` が受信箱の未読判定に使う`share_links.updated_at`を、同一リクエスト内の`recordView()`が先に更新してしまい、**未読が恒久的に消えない**バグ（受信箱の中心機能が機能しない状態）。時刻取得の順序を修正し回帰テストを追加。
中2件も同時修正: iOS受信箱DTOの`scope_name`/`owner.account_id`がnull1件で一覧全体デコード失敗する問題（Optional化）、`DeepLinkRouter`がコールドスタート時`AuthState.unknown`を未ログイン扱いしていた問題。
`.claude/rules/feedback_review_patterns.md` に `BE-7`（`@updatedAt`を既読判定の基準に使う罠）を追記。
main へマージ済み（コミット `5c2e4f6`）。worktree/ブランチは削除済み。

### 検証結果（レビュー後・最終）

- BE: `npx tsc --noEmit`（クリーン）/ `npm test`（**87 suites / 884 tests 全緑**）/ `npm run build`（成功）
- iOS: `xcodebuild` BUILD SUCCEEDED、Domain 207 / Network 165 テスト全緑

### トレードオフ・残課題

- **KPI 再設定が未着手**: 公開経路の廃止により `docs/09` の KPI「共有リンク経由の新規インストール比率 ≥ 10%」（Phase 1・Phase 2 とも）は達成不能。`docs/09-roadmap.md` に取消線 + 脚注で明記済み。**削除するか置き換えるかの意思決定は未着手**（本計画のスコープ外）
- 手動確認手順（`plan.md` §9・11項目）は実機/シミュレータで未実施（実DB・複数アカウントが必要なため）
- レビューで見つかった中3件・軽微4件のうち、レート制限実装の3方式分裂は未修正のまま残る（`review.md`に申し送り事項として記録済み。実害小さく緊急対応不要）。**「他招待者閲覧で全員未読化」は2026-08-09に修正済み**（`docs/plans/bugfix-batch1/review.md`参照）。**「tour名解決のdeletedAt未考慮」「`TokenThrottlerGuard`デッドコード」は2026-08-14に修正済み**

## 10. 既知バグの横断調査・修正 — `docs/plans/bugfix-batch1/`（2026-08-09 完了）

過去の全`review.md`を横断調査し、「重大ゼロ」基準クリアのため未修正のまま残っていた中優先度バグを洗い出し、影響度の高い4件のうち3件を修正（1件は`share-account-invites`実装時に既に解消済みと判明）。

| バグ | 内容 | 状態 |
|---|---|---|
| 読み取り専用共有の行ID重複 | 同一公演・同一代表名義の複数申込でSwiftUIの`ForEach`行が衝突 | ✅ 既に解消済み（共有招待制T6のモデル書き換えで`rowIndex`込みのidに変更されていた） |
| ログアウト直後のトークン競合 | refresh完了がログアウト後に間に合うとKeychainに新トークンが書き戻り、黙って復帰する | ✅ 修正（`ApiClient.swift`。Keychain書き込みを決定順に直列化） |
| アカウント削除シートの操作不能 | Apple再認可の無応答でシートの「閉じる」も押せなくなる | ✅ 修正（60秒タイムアウト追加） |
| 受信箱の未読誤リセット | 招待者Aの閲覧で招待者Bの未読フラグが誤ってtrueに戻る | ✅ 修正（判定基準を`updated_at`→`last_edited_at`へ） |

レビューで、上記修正**自体が生んだ**新たな重大バグ2件を追加発見・修正:
- ログアウト競合の修正が、サインイン直後に別経路の書き込みを打ち消してサイレントログアウトさせる鏡像バグを作っていた
- 削除シートの緩和が、「閉じる」を押した後もバックグラウンドでアカウント削除が進行し続ける（不可逆操作がユーザーのキャンセル後に実行される）バグを作っていた

`.claude/rules/feedback_review_patterns.md`にIOS-13（`await`後の「打ち消し」後始末は決定順の直列化に置き換える）を追記。
検証: BE 887テスト・iOS Networking 167テスト全緑、`xcodebuild` BUILD SUCCEEDED。

**残っている既知の未修正バグ**（影響度: 中〜低、緊急対応不要）:
- 同期エンジンのリトライバックオフ（`nextRetryAt`/`attemptCount`）が未読のまま機能していない
- `sync/pull`カーソルページングで`updated_at`同値行の取りこぼしの可能性
- レート制限実装の3方式分裂、AdMobポーリングの過剰実行など（保守性のみ）

（2026-08-13 削除・訂正: 「共有ペイロードで同行者名がマスクされない」はバグではなく`docs/04-api.md:564`に明記された意図的な契約と判明したため削除。「同期の恒久失敗（`SYNC_APPLY_FAILED`）がUIに表示されない」は修正済み — `SyncEngine.swift`のLWW競合以外のrejectを`SyncStatus.failed`に反映するよう変更。バックオフ未実装は引き続き既知課題として上記に残す。）
（2026-08-14 削除: 「削除済みツアーが受信箱に名前付きで残る」は修正済み。`resolveTourNames`に`deletedAt: null`を追加し、`ListInboxUseCase`で名前解決できなかった行を一覧から除外するよう変更。詳細は§9参照。）

## ファイル所有表（同時に触らせないファイル。iOS T1b/T2/T3を並列発行する際に必ず確認）

`docs/plans/ios-network-integration/plan.md` §2.1 が正。T0/T1が確定させた基盤（`ApiClient.swift`・`TokenStore.swift`・`AuthStore.swift`・Repository protocol定義）は以後読み取り専用。

共有招待制化（計画 9）に着手する際は `docs/plans/share-account-invites/plan.md` §2.1 のファイル所有表も併せて確認すること（`schema.prisma` / `app.module.ts` / `error-codes.ts` / `AppEnvironment.swift` / `AppRoute.swift` が直列必須）。

## 運用ルール

- 各タスク完了時、このファイルの該当行のステータスを更新すること
- 新しい計画（`docs/plans/<feature>/`）を起票したら、本ファイルの「全体像」と該当セクションを追記すること
- サブエージェントへの委譲プロンプトには本ファイルへのパスを含めてよい（全体進捗の把握用。詳細は各計画のファイルを参照させる）
