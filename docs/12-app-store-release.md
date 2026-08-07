# 12. App Store 提出手順

TestFlight配信・審査提出までの手順です。**現状（2026-08-07時点）でこのリポジトリだけでは完了しません** —
ユーザー側で用意する外部リソース（Apple Developer Program・署名・本番API等）が複数あります。
2章に「今すぐできないこと」を先にまとめているので、まずそこを確認してください。

---

## 1. 現状の未整備事項（着手前に確認）

| # | 項目 | 状態 | 必要な対応 |
|---|---|---|---|
| U1 | Apple Developer Program 登録 | 未確認 | 年会費 $99 で登録（個人 or 組織） |
| U2 | `DEVELOPMENT_TEAM`（署名チームID） | 空文字（`meigicho/project.yml`） | Apple Developer のチームIDを設定 |
| U3 | Sign in with Apple Capability | 未設定（`.entitlements` なし） | [11-dev-environment-setup.md §4.2](./11-dev-environment-setup.md#42-sign-in-with-apple追加設定が必要未検証) |
| U4 | Google OAuth クライアントID | 未取得 | [11-dev-environment-setup.md §4.3](./11-dev-environment-setup.md#43-google-sign-in追加設定が必要未検証) |
| U5 | 本番API（Cloud Run）のデプロイ | 未実施 | [06-infrastructure.md](./06-infrastructure.md) §4。`meigicho/project.yml` の `Release.API_BASE_URL` は `https://api.meigicho.example` の**ダミー値** |
| U6 | RevenueCat（課金） | **一時無効化中**（`Network`パッケージ名衝突のため） | `docs/plans/STATUS.md` §3 の手順で再有効化してから本番課金キーを設定 |
| U7 | AdMob 実アカウント・広告ユニットID | 未取得（テストID使用中） | `docs/plans/admob-integration/plan.md` §10.1（U1〜U8） |
| U8 | App Store Connect 上のアプリ登録 | 未実施 | 3節 |
| U9 | プライバシーポリシー・利用規約の公開URL | 未整備 | `docs/08-compliance-risk.md` §2.6 のチェックリストに従い作成・ホスティング |
| U10 | App アイコン・スクリーンショット | 未確認 | `docs/08-compliance-risk.md` §1.2「スクリーンショット構成（5枚）」参照 |

**U1〜U4・U6・U7・U9・U10 はこのセッションでは用意できません（秘密情報・外部アカウント・デザイン成果物のため）。**
まず TestFlight の内部テストまでを目標にするなら、U1・U2・U5・U8 が最小セットです
（Sign in with Apple / Google / 課金 / 広告は未設定のままでもアプリはクラッシュせず動作します）。

---

## 2. 全体の流れ

```
① Apple Developer Program 登録
② 署名設定（DEVELOPMENT_TEAM・Bundle ID・Capability）
③ App Store Connect でアプリを新規登録
④ 本番BEをCloud Runにデプロイし、Release用 API_BASE_URL を設定
⑤ バージョン番号を上げてアーカイブ
⑥ Xcode Organizer から App Store Connect へアップロード
⑦ TestFlight で内部/外部テスト
⑧ App Store Connect のメタデータ（説明文・スクショ・プライバシー申告）を入力
⑨ 審査に提出
```

---

## 3. 署名設定

1. [Apple Developer Program](https://developer.apple.com/programs/) に登録し、チームIDを控える
2. `meigicho/project.yml` を編集:
   ```yaml
   targets:
     Meigicho:
       settings:
         base:
           DEVELOPMENT_TEAM: "<取得したチームID>"
   ```
3. Bundle ID は現状 `jp.meigicho.app`（`project.yml` の `PRODUCT_BUNDLE_IDENTIFIER`）。
   [Apple Developer > Identifiers](https://developer.apple.com/account/resources/identifiers/list) で同じ Bundle ID を登録し、
   **Sign in with Apple** の Capability を有効化する
4. Xcode で `Meigicho` ターゲット → *Signing & Capabilities* → *Automatically manage signing* を有効にし、
   Team を選択（`+ Capability` で *Sign in with Apple* を追加。11章 §4.2 の注記参照）
5. `xcodegen generate` → 再ビルドして署名エラーが無いことを確認

---

## 4. App Store Connect でアプリを登録

1. [App Store Connect](https://appstoreconnect.apple.com/) → *My Apps* → *+* → *New App*
2. Bundle ID に `jp.meigicho.app` を選択、名称・プライマリ言語（日本語）・SKUを入力
3. *App Information* でカテゴリ・年齢制限（コンテンツレーティング）を設定
4. *App Privacy* に進み、収集データを申告する（下記5節参照）

---

## 5. App Privacy 申告（App Store Connect > App Privacy）

`docs/08-compliance-risk.md` §2.6 に必須条項チェックリストがある。実装から申告すべき項目:

| データ種別 | 収集有無 | 用途 | 参照 |
|---|---|---|---|
| メールアドレス | 収集する（メール+パスワード認証） | アカウント機能 | `docs/04-api.md` §3.1 |
| 氏名（ユーザー本人・家族/友人） | 収集する（暗号化保存、下4桁表示） | アプリ機能 | `docs/08` §2 |
| 購入履歴 | 収集する（RevenueCat経由） | アプリ機能・分析 | `docs/07-monetization.md` §9 |
| 広告データ | 収集する（AdMob・**非パーソナライズ広告固定**） | 広告表示 | `docs/08` §2.8、`docs/07` §7 |
| 識別子（デバイスID等） | AdMob SDKが技術的に使用（NPA固定でトラッキング目的では使用しない） | 広告配信 | 同上 |

**トラッキング（IDFA）を目的とした収集は行わない**（ATTなし・NPA固定の方針。`docs/08` §2.8）。
`NSUserTrackingUsageDescription` が Info.plist に**存在しないこと**を確認する（AdMobレビューで確認済み）。

---

## 6. 本番バックエンドのデプロイ

Release ビルドは `meigicho/project.yml` の `configs.Release.API_BASE_URL` を参照する
（現状ダミー値 `https://api.meigicho.example`）。[06-infrastructure.md](./06-infrastructure.md) は構成・コスト試算・`gcloud run deploy`のコマンド例が中心で、
**「アカウント・プロジェクトを何もない状態から作る」手順は無い**ため、ここに初回セットアップの手順をまとめる
（既にSupabase/GCPプロジェクトがある場合は 6.3 から）。

### 6.1 Supabase プロジェクトを作る

1. [supabase.com](https://supabase.com/) でアカウント作成 → *New Project*
2. リージョンは **Tokyo（`ap-northeast-1`）** を選択（`docs/08-compliance-risk.md` §2.1 の越境移転回避方針）
3. プロジェクト作成後、*Project Settings* → *Database* → *Connection string* から
   **Connection pooling（Transaction mode）** の接続文字列を控える（`?pgbouncer=true` 付き）。
   これが本番用 `DATABASE_URL` になる
4. スキーマを反映する（ローカルから直接、または後述のCI経由）:
   ```bash
   cd apps/api
   DATABASE_URL="<Supabaseのpooler接続文字列>" npx prisma db push
   ```
   **`.env` は書き換えず、コマンドラインでその場だけ環境変数を渡すこと**（本番接続文字列を平文でリポジトリに残さない）

### 6.2 GCP プロジェクトを作る

1. [Google Cloud Console](https://console.cloud.google.com/) で新規プロジェクトを作成（例: `meigicho-prod`）
2. 課金アカウントを紐付ける
3. 必要な API を有効化:
   ```bash
   gcloud config set project meigicho-prod
   gcloud services enable run.googleapis.com \
     artifactregistry.googleapis.com \
     secretmanager.googleapis.com \
     iam.googleapis.com
   ```
4. Artifact Registry リポジトリを作成:
   ```bash
   gcloud artifacts repositories create meigicho \
     --repository-format=docker \
     --location=asia-northeast1
   ```
5. デプロイ用サービスアカウントを作成し、権限を付与:
   ```bash
   gcloud iam service-accounts create meigicho-api \
     --display-name="meigicho API runtime"

   gcloud projects add-iam-policy-binding meigicho-prod \
     --member="serviceAccount:meigicho-api@meigicho-prod.iam.gserviceaccount.com" \
     --role="roles/secretmanager.secretAccessor"
   ```
6. Secret Manager にシークレットを登録（値は `apps/api/.env.example` のキー一覧を参照。
   実際の値はユーザー自身が用意 — エージェントは秘密ファイル保護のため代行不可）:
   ```bash
   echo -n "<6.1で控えたSupabase接続文字列>" | gcloud secrets create database-url --data-file=-
   echo -n "<ランダムな長い文字列>" | gcloud secrets create jwt-secret --data-file=-
   echo -n "<RevenueCat Webhook Secret>" | gcloud secrets create rc-webhook --data-file=-
   ```
   `apps/api/.env.example` に記載の他の変数（`GOOGLE_CLIENT_IDS` / `RESEND_API_KEY` 等）も同様に登録する
   （`docs/plans/STATUS.md` §2「BE残課題」参照）

### 6.3 初回デプロイ（手動）

```bash
cd apps/api
docker build -t asia-northeast1-docker.pkg.dev/meigicho-prod/meigicho/api:v1 .
gcloud auth configure-docker asia-northeast1-docker.pkg.dev --quiet
docker push asia-northeast1-docker.pkg.dev/meigicho-prod/meigicho/api:v1

gcloud run deploy meigicho-api \
  --image=asia-northeast1-docker.pkg.dev/meigicho-prod/meigicho/api:v1 \
  --region=asia-northeast1 \
  --platform=managed \
  --allow-unauthenticated \
  --min-instances=0 --max-instances=10 \
  --cpu=1 --memory=512Mi --concurrency=80 --timeout=30 --cpu-boost \
  --service-account=meigicho-api@meigicho-prod.iam.gserviceaccount.com \
  --set-secrets="JWT_SECRET=jwt-secret:latest,DATABASE_URL=database-url:latest,REVENUECAT_WEBHOOK_SECRET=rc-webhook:latest" \
  --set-env-vars="NODE_ENV=production"
```

デプロイ完了後に表示される `https://meigicho-api-xxxxx-an.a.run.app` 形式のURLが本番APIのURL。
`curl <URL>/health` で疎通確認する。

### 6.4 継続デプロイ（任意・CI化する場合）

2回目以降のデプロイを手動で繰り返さないなら、[06-infrastructure.md](./06-infrastructure.md) §7 の
GitHub Actions ワークフロー例（Workload Identity Federation・キーレス認証）をそのまま使える。
`.github/workflows/deploy-api.yml` は未作成のため、導入する場合は同§7の内容をコピーして
`PROJECT_ID` / `secrets.GCP_WIF_PROVIDER` を6.2で作った値に置き換える。

### 6.5 iOS側にURLを反映

1. デプロイ後の実URLを `meigicho/project.yml` に設定:
   ```yaml
   configs:
     Release:
       API_BASE_URL: https://<6.3で確認した実際のCloud Run URL>
   ```
2. `xcodegen generate` → Release ビルドで疎通確認

---

## 7. バージョン番号を上げる

`meigicho/project.yml` に `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` の指定が無いため、
Xcode の既定値（`1.0` / `1`）のまま。リリースのたびに上げる場合は `project.yml` に追記する:

```yaml
targets:
  Meigicho:
    settings:
      base:
        MARKETING_VERSION: "1.0.0"      # ユーザーに見えるバージョン
        CURRENT_PROJECT_VERSION: "1"    # ビルド番号。提出ごとに必ずインクリメント
```

---

## 8. アーカイブとアップロード

Xcode から:

1. スキームを `Meigicho`、実行先を **Any iOS Device (arm64)** に変更（シミュレータではアーカイブ不可）
2. *Product* → *Archive*
3. ビルド完了後、Xcode Organizer が開く → 対象アーカイブを選択 → *Distribute App*
4. *App Store Connect* → *Upload* → 署名は自動管理のまま進める
5. アップロード完了後、App Store Connect の *TestFlight* タブに処理中として表示される（数分〜数十分）

コマンドラインでも可能（CI化する場合）:

```bash
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS' \
  -archivePath /tmp/meigicho.xcarchive archive

xcodebuild -exportArchive \
  -archivePath /tmp/meigicho.xcarchive \
  -exportPath /tmp/meigicho-export \
  -exportOptionsPlist <exportOptions.plist>
```

`exportOptions.plist` は `method: app-store-connect` を指定した設定ファイルを別途用意する
（`teamID` に U2 のチームIDを記載）。

---

## 9. TestFlight

1. App Store Connect > TestFlight でビルドの処理完了を待つ
2. **輸出コンプライアンス**の質問に回答（暗号化: HTTPS通信のみで独自暗号は使用していない場合は該当なしで進められることが多いが、最終判断は提出時の質問文に従う）
3. 内部テスター（Apple ID）を追加してすぐ配信可能。外部テスターは簡易審査（Beta App Review）が必要
4. `docs/08-compliance-risk.md` §1.6 の**レビューノート**をこの段階で App Review Information に先に書いておくと、後の本審査提出がスムーズ

---

## 10. 審査提出チェックリスト（`docs/08` §2.6 / §1.6 の要約）

提出前に以下を確認する（詳細は `docs/08-compliance-risk.md` を参照）:

- [ ] App Store 説明文・スクリーンショット・アプリ名が実際の挙動と一致している（§1.1/1.2、5.6対策）
- [ ] レビューノート（§1.6のドラフト）を App Review Information に記載済み
- [ ] テスト用アカウントを用意し、認証情報を App Review Information に記載
- [ ] プライバシーポリシー・利用規約のURLが有効（§2.6チェックリスト）
- [ ] App内課金の説明・スクリーンショットを登録、EULAリンクが利用規約と矛盾しない（§2.6）
- [ ] Sign in with Apple: 他ソーシャルログインを提供する場合は Apple も必須（Guideline 4.8）— 実装済み
- [ ] ゲストモード（未ログイン閲覧）が機能している（Guideline 5.1.1(v)対応、実装済み）
- [ ] アカウント削除がアプリ内から完結する（Guideline 2.5、実装済み。`DELETE /v1/me`）
- [ ] App Privacy 申告が実装と一致（本ドキュメント5節）
- [ ] `NSUserTrackingUsageDescription` が **存在しない**こと（ATT非使用の方針と一致させる）

---

## 11. 審査提出後

- レビュー結果が「拒否」の場合、`docs/08-compliance-risk.md` §1.6「追加で聞かれた場合の回答方針」の表を参照して Resolution Center で回答する
- 承認後は App Store Connect で公開日を「手動リリース」か「自動リリース」か選択して提出

---

## 関連

- 開発環境の接続: [11-dev-environment-setup.md](./11-dev-environment-setup.md)
- インフラ・本番デプロイ: [06-infrastructure.md](./06-infrastructure.md)
- 審査・法務リスクの詳細: [08-compliance-risk.md](./08-compliance-risk.md)
- 現在の実装進捗: [docs/plans/STATUS.md](./plans/STATUS.md)
