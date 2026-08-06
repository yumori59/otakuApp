# STATUS — 開発進捗（横断サマリ）

**このファイルの目的**: 複数セッション・複数サブエージェントが現在の全体進捗を素早く把握するための単一の参照点。
各計画の詳細は `docs/plans/<feature>/` 配下（`requirements.md` / `api-contract*.md` / `plan.md` / `review.md`）を正とする。
本ファイルは索引であり、内容が古くなったら都度更新する（作業開始・完了のたびに反映すること）。

最終更新: 2026-08-05

---

## 方針決定（横断）

| 日付 | 決定 | 影響 |
|---|---|---|
| 2026-08-05 | **アプリ不要の独立共有 Web（Next.js / Cloudflare Pages）は作らない** | 閲覧・編集の正は iOS `SharedBoard` + `GET/PATCH /public/shares/:token`。`docs/00`〜`09`・本 STATUS を更新。roadmap 1-7 は廃止（工数 0）。Universal Links は任意の後続 |

---

## 全体像

```
BE: ドメイン + 認証拡張 + home/stats/sync/billing（2026-08-05 完了）
iOS: ネットワーク接続・home/summary・ペイウォール・stats/identities 接続（2026-08-05）
次: 同期エンジン（`docs/plans/ios-sync-engine/`）→ AdMob（Phase 1-11）
共有: 独立 Web ビューは対象外。アプリ内 SharedBoard が正
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
cd meigicho/Packages/Network && swift test
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
| AdMob（バナー・ネイティブ・リワード） | ❌ | `docs/07` §7, `09` 1-11 |
| `AdSlot` / 広告禁止画面の型ガード | ❌ | `docs/05` §7 |

**iOS 課金の現状**: `PaywallView`・`PurchasesStore`・`RevenueCatPurchasesService` 実装済み。`REVENUECAT_API_KEY` 未設定時は `DisabledPurchasesService` でスタブ動作。4件目名義追加・共有2本目・設定画面からペイウォール表示。`xcodebuild` BUILD SUCCEEDED（Domain 152 / Network 144 tests 全緑）。

**広告の現状**: 設計のみ（`docs/07-monetization.md` §7）。コードベースに Google Mobile Ads SDK・`AdSlot`・広告ユニット ID は**一切無し**。Phase 1 の roadmap 1-11（工数 4.0人日）。NPA 固定・ATT なしで開始（`docs/08` §2.8）。

## 7. iOS — stats / sync

| 機能 | 状態 | 参照 |
|---|---|---|
| `GET /v1/stats/identities` iOS 接続（Store + 名義一覧/詳細の当選数） | ✅ | `docs/04` §3.5 |
| 統計画面（タブ・グラフ・Plus ソフトウォール） | ❌ | `docs/09` 1-5 / `docs/07` §6.2-C |
| 同期エンジン（DataStore + SyncEngine） | 📋 T0–T2 ✅（identities 同期）→ 次 T3 他コレクション / T4 配線 | `docs/plans/ios-sync-engine/` |

---

## ファイル所有表（同時に触らせないファイル。iOS T1b/T2/T3を並列発行する際に必ず確認）

`docs/plans/ios-network-integration/plan.md` §2.1 が正。T0/T1が確定させた基盤（`ApiClient.swift`・`TokenStore.swift`・`AuthStore.swift`・Repository protocol定義）は以後読み取り専用。

## 運用ルール

- 各タスク完了時、このファイルの該当行のステータスを更新すること
- 新しい計画（`docs/plans/<feature>/`）を起票したら、本ファイルの「全体像」と該当セクションを追記すること
- サブエージェントへの委譲プロンプトには本ファイルへのパスを含めてよい（全体進捗の把握用。詳細は各計画のファイルを参照させる）
