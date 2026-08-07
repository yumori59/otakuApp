# 11. 開発環境の接続手順

BE（Docker）と iOS（Xcode）を実際に繋いで手元で動かすための手順です。
Docker 単体の詳細は [local-dev-docker.md](./local-dev-docker.md) が正、本章は **iOS 側も含めた end-to-end** の手順を扱います。

対象読者: このリポジトリを初めて手元で動かす人。

---

## 1. 前提

| 項目 | 必要なもの |
|---|---|
| BE | Docker Desktop（または Docker Engine + Compose v2） |
| iOS | Xcode 16 以上、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`） |
| ポート | `5432`（PostgreSQL）・`8080`（API）が空いていること |

---

## 2. BE を起動する（Docker）

```bash
# リポジトリルートで
make up

# 起動確認
make health
# => {"status":"ok"}
# => {"status":"ready","database":"connected"}
```

停止は `make down`。ログは `make logs`。これで `http://localhost:8080` に API が立ちます。

**ホストで NestJS を watch 起動したい場合**（ホットリロードが欲しいとき）:

```bash
make db-only          # DB だけ Docker で起動
cd apps/api && npm install
make api-dev           # NestJS watch 起動（.env は .env.example から自動コピーされる）
```

---

## 3. iOS アプリをシミュレータから接続する

`meigicho/project.yml` の `Debug` 設定は既に `API_BASE_URL: http://localhost:8080` を向いています。
**シミュレータは Mac 本体と同じネットワーク namespace なので、追加設定なしで `localhost:8080` に届きます。**
（実機で試す場合は 6 節を参照）

```bash
cd meigicho
xcodegen generate
open Meigicho.xcodeproj
```

Xcode で `Meigicho` スキーム・iOS シミュレータを選んで実行（⌘R）。BE が `make up` 済みであれば、
起動直後のホーム画面が「ログインしてください」または未ログイン閲覧モードで表示されます。

コマンドラインでビルドだけ確認したい場合:

```bash
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
```

---

## 4. ログインを試す

### 4.1 メール+パスワード（最も手軽。追加設定不要）

BE が起動していれば、アプリの「メールで登録」からその場でアカウントを作れます。
API を直接叩いてテスト用アカウントを先に作っておくこともできます:

```bash
curl -s -X POST http://localhost:8080/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"dev@example.com","password":"Password123!","display_name":"開発用"}'
```

### 4.2 Sign in with Apple（追加設定が必要・未検証）

現状 **Xcode 側に Sign in with Apple の Capability・署名が未設定**（`.entitlements` ファイルが存在しない、
`project.yml` の `DEVELOPMENT_TEAM` が空文字）。実際に Apple でログインするには:

1. Apple Developer Program のチームID を取得し、`meigicho/project.yml` の
   `targets.Meigicho.settings.base.DEVELOPMENT_TEAM` に設定する
2. Xcode で `Meigicho` ターゲット → *Signing & Capabilities* → **+ Capability** → *Sign in with Apple* を追加する
   （XcodeGen が `.entitlements` を生成していないため、Xcode 上で一度追加すると `project.yml` に
   `entitlements` ブロックが必要になる。追加後 `xcodegen generate` で消えないよう `project.yml` 側にも反映すること）
3. シミュレータでは Apple ID の実サインインが求められる場合がある（実機の方が安定）

未設定のままでも「Apple でサインイン」ボタン自体は表示されるが、実際にタップすると失敗する。

### 4.3 Google Sign-In（追加設定が必要・未検証）

1. Google Cloud Console で OAuth クライアント（iOS 種別）を作成し、`GOOGLE_IOS_CLIENT_ID` と
   逆引き形式の `GOOGLE_REVERSED_CLIENT_ID` を取得する
2. `meigicho/project.yml` の `settings.base.GOOGLE_IOS_CLIENT_ID` / `GOOGLE_REVERSED_CLIENT_ID` に設定
3. `apps/api/.env`（`.env.example` からコピーしたもの）に BE 側の変数を追記する:
   ```
   GOOGLE_CLIENT_IDS=<iOSクライアントID>
   GOOGLE_ISSUER=https://accounts.google.com
   GOOGLE_JWKS_URL=https://www.googleapis.com/oauth2/v3/certs
   ```
   **iOS の `GOOGLE_IOS_CLIENT_ID` と BE の `GOOGLE_CLIENT_IDS` は同じ値であること**が動作条件
4. `xcodegen generate` → 再ビルド

未設定時は「Google でサインイン」ボタンは表示されるが、理由付きで無効化される（クラッシュしない）。

---

## 5. 課金・広告 SDK を試す（任意）

すべて未設定でも動く（`Disabled*` フォールバックで安全に無効化される）。試す場合のみ:

| 変数 | 設定場所 | 用途 |
|---|---|---|
| `REVENUECAT_API_KEY` | `project.yml` | 課金（現状 RevenueCat は `Network` パッケージ名衝突のため**コメントアウトで無効化中**。再有効化手順は `docs/plans/STATUS.md` §3） |
| `ADMOB_APP_ID` / `ADMOB_UNIT_*` | `project.yml` | 広告（現状 `ADMOB_APP_ID` は Google 公式テストIDが既定値。`ADMOB_UNIT_*` を Google テストユニットID `ca-app-pub-3940256099942544/2934735716` にすると Stage 1 のバナー3面が試せる） |

---

## 6. 実機での接続（任意）

実機は `localhost` に届かないため、Mac の LAN IP か `ngrok` 等のトンネルが必要。

```bash
# Mac の LAN IP を確認
ipconfig getifaddr en0
```

`meigicho/project.yml` の `configs.Debug.API_BASE_URL` を `http://<MacのIP>:8080` に変更し、
`xcodegen generate` → 実機ビルド。実機は署名（`DEVELOPMENT_TEAM`）が必須。

Info.plist の `NSAppTransportSecurity` は現状 `NSAllowsLocalNetworking: true` のみで、
任意ホストへの平文通信は許可していない。LAN IP 経由で `ATS` に弾かれる場合は
一時的に該当ホストの例外を `project.yml` の `NSAppTransportSecurity` に追加する（本番設定に戻すこと）。

---

## 7. うまくいかないとき

| 症状 | 確認すること |
|---|---|
| `make health` が失敗する | `docker compose ps` でコンテナが起動しているか。ポート `5432`/`8080` が他プロセスに使われていないか |
| iOS がネットワークエラーになる | `curl http://localhost:8080/health` がMacのターミナルから通るか。シミュレータ再起動で直ることがある |
| `xcodegen generate` 後もビルドが直らない | `project.pbxproj` に古い設定が焼き込まれている可能性（IOS-8）。`Meigicho.xcodeproj` を削除して `xcodegen generate` からやり直す |
| クリーンビルドで急に落ちる | `Package.resolved` の再生成漏れ。`meigicho/Meigicho.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` を削除して再ビルド |

---

## 関連

- BE単体の詳細: [local-dev-docker.md](./local-dev-docker.md)
- 本番デプロイ（Cloud Run）: [06-infrastructure.md](./06-infrastructure.md) §4
- App Store への提出手順: [12-app-store-release.md](./12-app-store-release.md)
