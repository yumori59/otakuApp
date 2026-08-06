# plan — ios-network-integration

前提: `requirements.md`（要件・制約・エッジケース）/ `contract-mapping.md`（**iOS 側 DTO ↔ Domain 契約の正**）/
`questions-requirements.md`（未確定事項の暫定確定 Q1〜Q14）。

API 契約の正は次の 2 本（**本計画では変更しない**）:

1. `docs/plans/backend-domain-modules/api-contract.md` — 基底契約
2. `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` — 認証拡張 + 共有 write の差分（**食い違う箇所はこちらが優先**）

> ## 改訂履歴
>
> **rev.2（BE 拡張反映）** — `questions-requirements.md` の **Q3 / Q7 がユーザー判断で覆った**。
>
> | Q | 旧（planner 推奨） | **確定** |
> |---|---|---|
> | Q3 | Google / メール+パスワードのログイン UI を**撤去**する | **撤去しない。Apple + Google + メール+パスワードの 3 方式に拡張**（App Store Guideline 4.8 は Apple を残すことで満たす）。BE 実装済み |
> | Q7 | 共有ボードの編集機能を**撤去**する | **撤去しない。BE の共有 write 権限（`PATCH /public/shares/:token/items/:item_key`）に接続**。BE 実装済み |
>
> これに伴い **T1 を T1 / T1b に、T4 を T4 / T4b に分割**した（T0・T2・T3・T5 の番号は不変）。
> リスク R2 / R6 は「止めどころ」ではなくなったため差し替え済み（§6）。

**着手前の必須条件**: `questions-requirements.md` の **Q5 / Q9** に `[Answer]` が入っていること。
**Q3 / Q7 は上表で確定済み**（着手をブロックしない）。他の Q は `[Assumed]` のまま進めてよい。
新規の判断が必要な項目は **Q15（Google id_token の取得方法）**（§7.2 に決定案。`[要確認]`）と
**Q16（共有ボードのエントリポイント）**（§7.7 に決定案。`[要確認]`）。

---

## 1. タスク一覧と依存関係

| Task | 内容 | 依存 | 担当候補 | 目安 |
|---|---|---|---|---|
| **T0** | 基盤（Core 追加・`Network` パッケージ新設 + **`PublicApiClient`**・Domain 型/protocol 整備・Store 分割・Features 大ファイル分割・project.yml・Composition Root 骨格・テストターゲット） | — | `swift-developer` **model: opus** | 1.5 人日 |
| **T1** | 認証基盤 + ソーシャル（**Apple + Google**・Keychain・401 refresh 直列化・ログインゲート・ログイン画面の骨格） | T0 | `swift-developer` **model: opus** | 1.5 人日 |
| **T1b** | **メール+パスワード**（`register` / `login` / `password` 変更 / リセット 2 本）+ プロフィール（`GET/PATCH /v1/me`・`auth_providers` 表示） | T1 | `swift-developer` **model: opus** | 1.5 人日 |
| **T2** | 名義 + 会員情報（`identities` / `memberships` の CRUD 接続・`PLAN_LIMIT_IDENTITY`・会員番号下4桁化） | T1 | `swift-developer` (sonnet) | 1.0 人日 |
| **T3** | 申込 + ツアー/公演（全件取得ループ・find-or-create POST・PATCH・tourID グルーピング・ホーム集計） | T1 | `swift-developer` **model: opus** | 1.5 人日 |
| **T4** | 共有リンク管理（**オーナー側**。`shares` 接続・**read/write の選択**・`edit_count` 表示・失効・`PLAN_LIMIT_SHARE_WRITE`） | T3 | `swift-developer` **model: opus** | 1.0 人日 |
| **T4b** | 共有ボード（**受け取り側**。token でボードを開く画面・状況/座席の編集を `PATCH /public/...` に接続・`rev` 楽観ロック・token の Keychain 保管） | T0・T4 | `swift-developer` **model: opus** | 1.5 人日 |
| **T5** | `code-reviewer`（**別セッション**・全差分） | T1〜T4b | `code-reviewer` (opus) | 0.5 人日 |

依存グラフ:

```
T0 ── T1 ──┬── T1b (email auth + me)
           ├── T2  (identities + memberships)
           └── T3  (applications + tours/events) ── T4 (shares: owner) ── T4b (shared board: recipient)
                                                                                 │
                                            T1b・T2・T3・T4・T4b ─────────────── T5 (review)
```

**model エスカレーション理由**（rule 02）:

- T0: 前例のない横断基盤（新規パッケージ 2 クライアント + 全 Domain 型の破壊的変更 + 14 画面のコンパイルエラー解消）
- T1: 認証（トークン保管・回転・並行 refresh の直列化。誤ると全機能が壊れる）
- T1b: 認証（パスワード変更/リセットは**成功時にサーバーが refresh を全件失効させる**。保存し忘れが自分自身のログアウトになる）
- T3: 複合 POST（find-or-create）・カーソルページング・3 テーブル join のマッピング
- T4: 共有（漏洩事故に直結。read/write の選択と上限エラーの扱い）
- T4b: **未認証経路での書き込み**（誤って Bearer を付ける・401 で誤ログアウトさせる・token をログに出す、いずれも事故）
- T2 のみ既存パターンに沿う定型 CRUD なので sonnet

---

## 2. 並列実行可能なタスク

| Wave | 実行するタスク | 根拠 |
|---|---|---|
| **Wave 0** | **T0 単独（直列必須）** | `project.yml` / `Models.swift` / `MeigichoApp.swift` / `Package.swift` × 5 という**共有ファイルの集中地帯**をこのタスクだけが触る。rule 03「iOS の Network / Composition Root は直列必須」 |
| **Wave 1** | **T1 単独（直列必須）** | `MeigichoApp.swift`（認証ゲート）・`ApiClient`（401 リトライ）・`TokenStore` を確定させる。ここが未確定のまま後続を並列で走らせると、全 Repository が「認証済み前提」を各自で発明する |
| **Wave 2** | **T1b・T2・T3 を同一メッセージで並列発行（3 並列）** | T0 でファイル分割済みのため編集対象が重ならない（§2.1 の所有表）。3 者とも T1 が確定した `ApiClient` / `AuthStore` を読むだけ。**T1b は `Features/Account/**` と `AuthStore.swift`、T2 は `Identities` 系、T3 は `Applications`/`Home` 系**で完全に分離する |
| **Wave 3** | **T4 単独** | T3 の `tourID` グルーピングと `ApplicationListView` の共有セクションに依存する（同一ファイル） |
| **Wave 4** | **T4b 単独** | T4 が確定させた `ShareLink.permission` / `IssuedShareLink.token` を受け取る。加えて `AppRoute.swift` / `MeigichoApp.swift`（`.onOpenURL`）を触るため直列にする |
| **Wave 5** | **T5（レビュー）単独** | 実装が並列でもレビューは集約（rule 03） |

**T4b を T4 と並列にしない理由**: 両者とも「共有」だが、T4b は `AppRoute.swift`（新ルート）と
`MeigichoApp.swift`（ディープリンク受け口）を触る。T4 も `AppSheet` の共有シートを触るため
`AppRoute.swift` で衝突する。**同一ファイルへの同時編集は rule 03 で禁止**。

### 2.1 同時に触らせないファイル（唯一の編集者）

| ファイル / ディレクトリ | 唯一の編集者 | 備考 |
|---|---|---|
| `meigicho/project.yml` | **T0** | Network パッケージ追加・configs・**Google の URL scheme（reversed client ID）** |
| `meigicho/App/MeigichoApp.swift` | T0 → T1 → **T4b** | T0 が骨格、T1 が認証ゲート、T4b が `.onOpenURL` 1 行。**それ以外は読み取りのみ**。DI 追加が必要になったら planner に差し戻す |
| `meigicho/App/Info.plist` | T0 → **T1** | T0 が `API_BASE_URL` + ATS、T1 が **`CFBundleURLTypes`（Google の reversed client ID / `meigicho` スキーム）** |
| `Packages/*/Package.swift`（4 つ + Network） | **T0** | platforms / testTarget / 依存 |
| `Packages/Domain/Sources/Domain/Models/Models.swift` | **T0** | 全型の破壊的変更（`contract-mapping.md` §3） |
| `Packages/Domain/Sources/Domain/Repositories/**` | **T0** | **protocol 8 本を T0 で宣言し切る**（`SharedBoardRepository` を含む） |
| `Packages/Domain/Sources/Domain/AppError.swift` | **T0** | 新規エラーコード 6 種を含めて T0 で定義し切る（`contract-mapping.md` §2.3） |
| `Packages/Core/Sources/Core/**` | **T0** | `UUIDv7` / `APIDateFormat` / `Nonce` / `PKCE`（`CryptoKit` SHA256 + base64url） |
| `Packages/Network/.../ApiClient.swift`・`Endpoint.swift`・`ErrorEnvelope.swift` | T0 → **T1** | T0 が骨格（送信・デコード・エラー変換）、T1 が 401 refresh を足す。後続は `DTO/` と `Remote*Repository.swift` を**自分の担当分だけ**追加 |
| `Packages/Network/.../PublicApiClient.swift` | **T0** | **未認証クライアント**（`contract-mapping.md` §5.1）。T4b は使うだけ |
| `Packages/Network/.../TokenStore.swift` | **T1** | 自分の refresh token（Keychain） |
| `Packages/Network/.../SharedBoardTokenStore.swift` | **T4b** | 受け取った共有 token（Keychain・**別 service 名前空間**） |
| `Packages/Network/.../GoogleSignInService.swift` | **T1** | `ASWebAuthenticationSession` + PKCE（§7.2） |
| `Packages/Domain/Sources/Domain/AuthStore.swift` | T1 → **T1b** | T1 が Apple/Google + ゲート、T1b がメール系メソッドを**追記**（T1 完了後なので衝突しない） |
| `Packages/Domain/Sources/Domain/ProfileStore.swift` | **T1b** | 新規 |
| `Packages/Features/Sources/Features/Account/SignInView.swift` | T1 → **T1b** | T1 が Apple + Google ボタン、T1b がメール欄・新規登録・パスワード忘れ導線を追記 |
| `Packages/Features/Sources/Features/Account/AccountView.swift`・`PasswordChangeView.swift`・`PasswordResetView.swift` | **T1b** | アカウント設定・パスワード変更・リセット |
| `Packages/Domain/Sources/Domain/IdentityStore.swift` | **T2** | T0 が分割して作る |
| `Packages/Features/Sources/Features/Identities/**`・`Detail/IdentityDetailView.swift`・`Forms/AddIdentityView.swift`・`Forms/AddMembershipView.swift` | **T2** | |
| `Packages/Domain/Sources/Domain/ApplicationStore.swift` | **T3** | T0 が分割して作る |
| `Packages/Features/Sources/Features/Applications/**`・`Home/**`・`Detail/ApplicationDetailView.swift`・`Forms/AddApplicationView.swift` | **T3** | |
| `Packages/Domain/Sources/Domain/ShareLinkStore.swift` | **T4** | 旧 `TourShareStore.swift` を改名・全面書き換え |
| `Packages/Features/Sources/Features/Share/**` | **T4** | |
| `Packages/Features/Sources/Features/Navigation/AppRoute.swift` | T0 → **T4b** | T4 は既存の `AppSheet.shareRecipients` を再利用し、**新ケースを足さない**（足したくなったら planner に差し戻す） |
| `Packages/Domain/Sources/Domain/SharedBoardStore.swift`・`Packages/Features/.../SharedBoard/**`・`App/DeepLinkRouter.swift` | **T4b** | 全部新規ファイル |
| `Packages/DesignSystem/Sources/DesignSystem/Components/ErrorBar.swift` | **T0** | 新規。後続は使うだけ |
| `Packages/DesignSystem/.../GoogleSignInButton`（`FormComponents.swift` 内） | **T1** | **削除しない**（Q3 の判断が覆ったため使い続ける）。ブランドガイドラインへの適合確認のみ |

**`ApplicationListView.swift` は T3 と T4 の両方が触る**（一覧本体と共有セクション）。
これが T4 を Wave 3（直列）に置いた理由。**並列にしない。**

**`AuthStore.swift` / `SignInView.swift` は T1 と T1b が触る**が、**Wave 1 → Wave 2 で直列**なので衝突しない。
T1b と同時に走る T2 / T3 はこの 2 ファイルを触らない。

---

## 3. T0: 基盤タスク（並列化の前提を作る）

**このタスクは「振る舞いを一切変えない」ことが原則。** ネットワーク接続はまだしない。
`InMemory*Repository`（`SampleData` を返す）を注入して、**今までと同じ画面が同じデータで出る**状態でビルドを通す。

### 3.1 `Core` への追加

| ファイル | 内容 |
|---|---|
| `UUIDv7.swift` | `docs/05-ios-client.md` §2.4 のコードをそのまま採用（`generate(date:)` / `timestamp(of:)`） |
| `APIDateFormat.swift` | `contract-mapping.md` §2.1 の 4 関数（`dateOnly(from:)` / `dateOnlyString(from:)` / `dateTime(from:)` / `dateTimeString(from:)`）。JST 固定カレンダーは既存 `DateFormatting.swift:4-8` と同じ生成方法にそろえる |
| `Nonce.swift` | `SecRandomCopyBytes` 32 byte → base64url（`+/=` を `-_` と除去に置換）。**Apple / Google の両方で使う** |
| `PKCE.swift` | `codeVerifier`（43〜128 文字の base64url）と `codeChallenge = base64url(SHA256(verifier))`（`CryptoKit`）。**Google の認可フロー用**（§7.2）。純関数なのでテストしやすい |
| `AppLogger.swift` | `os.Logger` の薄いラッパー。`error(code:requestID:)` のみ公開し、**message 本文とトークンを受け取らない引数設計**にする（NFR-4 を型で守る） |

`Package.swift` に `platforms: [.iOS(.v17), .macOS(.v14)]` と `.testTarget(name: "CoreTests")` を追加（Q13）。

### 3.2 `Packages/Network` 新設

```
Packages/Network/
  Package.swift               // depends: Core, Domain / platforms: iOS 17
  Sources/Network/
    ApiClient.swift           // 認証あり: URLSession + send/sendVoid + Bearer 注入 + (T1で)401 refresh
    PublicApiClient.swift     // 認証なし: /public/* 専用。Bearer を付けない・401 リトライを持たない
    ApiConfiguration.swift    // baseURL / timeouts
    Endpoint.swift            // method・path・query・body（純粋な URLRequest 組み立て）
    ErrorEnvelope.swift       // envelope デコード + AppError への変換（両クライアントで共有）
    DTO/                      // 空（後続タスクが自分の担当分を追加）
    Remote/                   // 空（同上）
```

- `Domain` を import してよい（protocol 実装のため）。**`Features` / `DesignSystem` / `SwiftUI` を import しない**
- `ApiClient` は `actor`。`accessToken` の保持と差し替えを内部に閉じる
- **T0 の時点では 401 リトライを実装しない**（T1 が足す）。`TODO(T1)` コメントを残す
- **`PublicApiClient` を必ず別型として作る**（`contract-mapping.md` §5.1）。理由:
  1. 公開経路に `Authorization` を付けない
  2. **公開経路の 401 で自分のアカウントをログアウトさせない**（`ApiClient` の refresh 経路に絶対つながないこと）
  3. `/v1` プレフィックスを付けない
  - `ApiClient` に `requiresAuth: Bool` フラグを足す案は**採らない**（付け忘れが両方向の事故になる）
- `Endpoint` は **`/v1` あり / なし**を型で表現する（`case versioned(path:)` / `case publicPath(path:)` 等）。文字列連結で分岐させない

### 3.3 `Domain` の再構成

1. **`Models.swift` の型変更**（`contract-mapping.md` §3 を 1 行ずつ適用）+ 新規型（`Tour` / `EventEntity` / `UserProfile` / `Entitlement` / `ShareLink` / **`SharedBoard` / `SharedBoardItem` / `SharedItemHandle` / `SharedItemSnapshot`**）+ 新規 enum（`Plan` / `ShareScope` / **`SharePermission`**）
2. **`Repositories/` に protocol 8 本を全部宣言**（`contract-mapping.md` §5。**`SharedBoardRepository` を含む**）。後続タスクが protocol を足さなくて済むようにする
3. **`AppError.swift`**（`contract-mapping.md` §2.3 の全ケース + `.unknown`）。
   **BE 拡張で増えた 6 コード**（`AUTH_GOOGLE_INVALID` / `AUTH_CREDENTIALS_INVALID` / `AUTH_RESET_CODE_INVALID` / `EMAIL_ALREADY_REGISTERED` / `PLAN_LIMIT_SHARE_WRITE` / `RATE_LIMITED`）も**ここで定義し切る**。
   `.shareItemConflict(current:)` はケースだけ定義し、**格上げロジックは T4b が `RemoteSharedBoardRepository` 内に書く**（汎用マッパーは常に `.conflict`）
4. **`LoadState.swift`**（`idle / loading / loaded / failed(AppError)`）
5. **`AppDataStore.swift` を 2 つに分割**:
   - `IdentityStore`: identities + memberships + それらの集計（`expiringMembershipCount` / `sortedIdentities(by:)`）
   - `ApplicationStore`: applications + tours + events + それらの集計（`filteredApplications` / `groupedByTour` / `upcomingWonEvents` / `awaitingResults` / `pendingResultCount`）
   - **名義またぎの集計**（`winCount(for:)` / `applications(for:)`）は `ApplicationStore` に置き、`IdentityStore` は結果を受け取る形にする（相互参照を作らない）
   - グルーピングキーを `tourName: String` → `tourID: UUID` に変更（F5）。`TourGroup { id: UUID, tour: Tour, items: [...] }`
   - `today` を `now: @Sendable () -> Date = { Date() }` 注入に変更（Q12）
6. **`Preview/InMemory*Repository.swift`**（`SampleData` を返す 7 実装）。`SampleData.swift` は Preview 専用に降格
7. `Package.swift` に `.macOS(.v14)` + `.testTarget(name: "DomainTests")`

### 3.4 `Features` の機械的ファイル分割（振る舞い不変）

並列化のためだけに分ける。**ロジックを書き換えない。**

| before | after |
|---|---|
| `Detail/DetailViews.swift`（382 行） | `Detail/IdentityDetailView.swift` / `Detail/ApplicationDetailView.swift` |
| `Forms/FormViews.swift`（346 行） | `Forms/AddIdentityView.swift` / `Forms/AddMembershipView.swift` / `Forms/AddApplicationView.swift` / `Forms/SheetContentView.swift` |
| `Share/ShareViews.swift`（147 行） | `Share/SharePreviewView.swift` / `Share/ShareRecipientsView.swift` |

`Applications/ApplicationListView.swift`（444 行）も
`ApplicationListView.swift` / `TourTableSection.swift` に分けると T3/T4 の衝突が減るが、
`TourTableSection` はローカル表と共有 UI が同じ `View` に同居しているため **T4 が最終形を決める**。T0 では分割しない。

### 3.5 `DesignSystem`

`Components/ErrorBar.swift` を追加（`questions-requirements.md` Q11 の表の 2 行目用）。
`GoogleSignInButton` / `LoginDivider` は **T1 が参照を消してから削除する**（T0 では残す）。

### 3.6 App / project.yml

- `project.yml`: `packages` に `Network` 追加、`targets.Meigicho.dependencies` に `Network` と `Domain` を追加、
  `configs` に `Debug` / `Release` と `API_BASE_URL` を定義
- `App/Info.plist`: `API_BASE_URL = $(API_BASE_URL)`、Debug 構成のみ `NSAppTransportSecurity.NSAllowsLocalNetworking = true`
- `App/AppEnvironment.swift`（新規）: `Info.plist` から baseURL を読み、`ApiClient` と 7 つの Repository を組み立てる。
  **`#if DEBUG` で `InMemory*Repository` に差し替えられるフラグ**（`-UITestUseInMemoryStores`）を用意する
- `MeigichoApp.swift`: `AppEnvironment` を構築し、各 Store に注入。**この時点では `InMemory*` を注入**して既存の見た目を維持

### 3.7 T0 の完了条件

- `xcodebuild ... build` が **BUILD SUCCEEDED**
- `cd meigicho/Packages/Core && swift test` / `cd meigicho/Packages/Domain && swift test` が green
- **シミュレータで起動し、従来と同じ 14 画面が同じサンプルデータで動く**（振る舞い不変の確認）
- `grep -rn "import Network" meigicho/Packages/Features` が **0 件**（IOS-5）
- `grep -rn "SampleData" meigicho/Packages/Features` が `#Preview` ブロック内のみ

---

## 4. 受入基準 → テストケース

`swift test`（Q13）で検証するもの = **AC-*-T**（純粋関数）。
シミュレータでの手動確認 = **AC-*-M**（rule 01 の iOS 例外）。手動手順は `make up` で API が起動している前提。

### 4.1 T0（基盤）

| AC-ID | 受入基準 | 検証 |
|---|---|---|
| AC-N-01-T | `UUIDv7.generate()` が version=7・variant=0b10 のビットを持ち、同一ミリ秒内で単調増加する | `CoreTests` |
| AC-N-02-T | `dateOnly(from: "2026-08-20")` が JST 2026-08-20 00:00 を返し、`dateOnlyString(from:)` で `"2026-08-20"` に戻る（往復） | `CoreTests` |
| AC-N-03-T | 端末 TZ を `America/Los_Angeles` にしても AC-N-02 の往復が壊れない | `CoreTests`（`TimeZone` を差し替え可能な設計にする） |
| AC-N-04-T | `dateTime(from:)` がフラクショナル秒あり (`...T12:05:00.000Z`) / なし (`...T12:05:00Z`) の両方を解釈する | `CoreTests` |
| AC-N-05-T | 未知の `code` を含む envelope が `.unknown(code:message:)` になり、既知ケースに丸められない | `DomainTests` |
| AC-N-06-T | `PLAN_LIMIT_IDENTITY` の `details` が欠落・型不一致でもクラッシュせず `limit`/`current` が nil になる | `DomainTests` |
| AC-N-07-T | `Relation` / `ApplicationStatus` の未知生値が `.other` / `.applied` にフォールバックし、フォールバックした事実がログ用の戻り値に現れる | `DomainTests` |
| AC-N-08-T | `Patchable.unchanged` はキーごと省略され、`.set(nil)` は `null` を出力する | `DomainTests` |
| AC-N-09-M | 起動して 14 画面が従来と同じサンプルデータで表示される（振る舞い不変） | 手動 |
| AC-N-10 | `Features` が `Network` を import していない | `grep` |
| AC-N-11-T | **`PKCE.challenge(for: verifier)` が RFC 7636 の既知ベクタと一致する**（`verifier="dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"` → `challenge="E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"`） | `CoreTests` |
| AC-N-12-T | `Endpoint` が `/v1` あり / なしを取り違えない（`publicPath` に `/v1` が付かない） | `DomainTests` or `CoreTests` |
| AC-N-13 | **`PublicApiClient` が `Authorization` ヘッダを組み立てるコードを持たない**。`TokenStore` / `ApiClient` を参照していない | `grep` + レビュー |

### 4.2 T1（認証基盤 + Apple + Google）

| AC-ID | 受入基準 | 検証 |
|---|---|---|
| AC-AUTH-01-T | `AuthSessionResponse` のデコードで `user.account_id` / `display_name` が `null` でも失敗しない | `DomainTests`（マッパー） |
| AC-AUTH-02-T | `expires_in: 3600` から `expiresAt` が「受信時刻 + 3540 秒」になる（60 秒マージン） | `DomainTests` |
| AC-AUTH-03-M | 未ログイン起動でログイン画面が出る。**Apple と Google の両方のボタンがある** | 手動 |
| AC-AUTH-04-M | Sign in with Apple でログインすると `MainTabView` に切り替わり、**サーバー発行の** `ACC-XXXXXX` が出る | 手動 |
| AC-AUTH-05-M | アプリを終了→再起動しても再ログインを要求されない（Keychain の refresh token で自動復帰） | 手動 |
| AC-AUTH-06-M | ログアウトするとログイン画面に戻り、再起動しても未ログインのまま | 手動 |
| AC-AUTH-07-M | access token が切れた状態（BE の `DEFAULT_ACCESS_TTL_SECONDS` を一時的に 10 秒にして再起動）でも操作が通る（自動 refresh） | 手動 |
| AC-AUTH-08-M | 上記状態で 5 つの画面を素早く切り替えても、ログアウトに落ちない（並行 401 で refresh が 1 回だけ） | 手動。`AppLogger` に refresh 実行回数を出して確認 |
| AC-AUTH-09-M | Keychain の refresh token を無効値に書き換えて起動するとログイン画面に戻る（アラートは出ない） | 手動 |
| AC-AUTH-10 | トークンが `print` / `Logger` に出ていない | `grep`（`accessToken` / `refreshToken` / `id_token` の出力箇所） |
| **AC-GG-01-T** | 認可 URL に `client_id` / `redirect_uri` / `response_type=code` / `scope=openid email profile` / `code_challenge` / `code_challenge_method=S256` / `nonce` / `state` が全て入る | `CoreTests`（URL 組み立ては純関数） |
| **AC-GG-02-T** | コールバック URL のパースで `state` 不一致を**拒否**し、`error=access_denied` をユーザーキャンセルとして扱う | `CoreTests` |
| **AC-GG-03-M** | Google ボタンでブラウザが開き、サインイン後にアプリへ戻ってログインが完了する | 手動 |
| **AC-GG-04-M** | Google のサインインを**途中でキャンセル**してもエラー表示にならず、ログイン画面に留まる | 手動 |
| **AC-GG-05-M** | BE の `GOOGLE_CLIENT_IDS` に iOS クライアント ID が入っていないと `AUTH_GOOGLE_INVALID` になり、「Google アカウントでの確認に失敗しました」が出る（**アプリがクラッシュ・無限ループしない**） | 手動（意図的に env を外して確認） |
| **AC-GG-06-M** | Google 経由でログイン後、`GET /v1/me` の `auth_providers` に `"google"` が入る | 手動 |
| **AC-GG-07** | `id_token` を**加工せず**そのまま `id_token` キーで送っている（Apple の `identity_token` と取り違えていない） | 実装 grep |

### 4.2b T1b（メール+パスワード + プロフィール）

| AC-ID | 受入基準 | 検証 |
|---|---|---|
| AC-EM-01-T | `RegisterRequest` / `LoginRequest` / `ResetPasswordRequest` の JSON キーが `email` / `password` / `code` / `new_password` で一致する | `DomainTests` |
| AC-EM-02-T | `AUTH_CREDENTIALS_INVALID` が `.credentialsInvalid` に、`EMAIL_ALREADY_REGISTERED` が `.emailAlreadyRegistered` に、`RATE_LIMITED` が `.rateLimited` に写る | `DomainTests` |
| AC-EM-03-T | パスワードのクライアント側バリデーションが **8〜128 文字のみ**（大文字必須などの独自ルールを足していない） | `DomainTests`（IOS-4） |
| AC-EM-04-T | リセットコードのバリデーションが `^\d{8}$` | `DomainTests` |
| AC-EM-05-M | 新規登録（`register`）が成功し、そのままログイン状態になる。再起動後も維持される | 手動 |
| AC-EM-06-M | 同じメールでもう一度登録すると「このメールアドレスは既に登録されています」が出る | 手動 |
| AC-EM-07-M | 登録したメール+パスワードでログインできる。**パスワードを間違えても「メールアドレスまたはパスワードが違います」しか出ない**（未登録と区別しない） | 手動 |
| AC-EM-08-M | パスワード変更が成功し、**変更後もそのまま操作を続けられる**（返ってきたトークンペアを Keychain に保存できている） | 手動。**保存漏れがあるとここで落ちる** |
| AC-EM-09-M | パスワード変更後、**別端末（またはシミュレータ 2 台目）が次の refresh でログイン画面に戻る** | 手動（可能なら） |
| AC-EM-10-M | Apple のみでログインしたアカウントでは「パスワードを変更」が**表示されない**（`auth_providers` に `"email"` が無い） | 手動 |
| AC-EM-11-M | パスワードリセット要求が **未登録メールでも同じ応答**（「登録されていれば送信しました」）になる | 手動 |
| AC-EM-12-M | メールで届いた 8 桁コードでリセットでき、**そのままログイン状態になる** | 手動（BE 非本番はコンソール出力にフォールバック） |
| AC-EM-13-M | 誤コードを 5 回入れると以後正しいコードでも失敗し、文言は毎回同じ | 手動 |
| AC-EM-14-M | `reset-request` を 15 分に 4 回叩くと「試行回数が上限に達しました」が出る（**自動リトライしていない**） | 手動 |
| AC-ME-01-M | ユーザーネーム / アプリ名を変更してフォーカスを外すと保存され、アプリ再起動後も残る | 手動 |
| AC-ME-02-M | 背景カラーを変更すると `theme_color` が保存され、再起動後も同じ色で起動する | 手動 |
| AC-ME-03-M | `PATCH /v1/me` に `account_id` / `plan` / `id` を含めていない | 手動 + 実装 grep |
| AC-ME-04-M | アカウント設定に「連携済みのログイン方法」が `auth_providers` から表示される。未知の値が増えてもクラッシュしない | 手動 |

### 4.3 T2（名義 + 会員情報）

| AC-ID | 受入基準 | 検証 |
|---|---|---|
| AC-ID-01-T | `IdentityResponse` → `Identity` マッパーが全 11 フィールドを埋める（1 つでも欠けたら失敗するテスト） | `DomainTests` |
| AC-ID-02-T | `Identity` → `CreateIdentityRequest` で `history_visible` の既定が **`false`** | `DomainTests` |
| AC-ID-03-T | `MembershipResponse` → `Membership` で `renewal_on` / `fee_yen` が null でも成功する | `DomainTests` |
| AC-ID-04-M | 名義を追加すると DB に入り、アプリ再起動後も残る | 手動（`make up` + 再起動） |
| AC-ID-05-M | 推しカラー / 備考 / 履歴公開トグルを変更すると再起動後も残る | 手動 |
| AC-ID-06-M | 新規名義の「当落履歴を公開」が **オフ** で作られる | 手動（Q9） |
| AC-ID-07-M | 4 件目の名義を追加すると「無料プランで登録できる名義は 3 件までです」が出る（ペイウォールは出ない） | 手動 |
| AC-ID-08-M | 会員情報の入力欄が「会員番号の下4桁（任意）」で、5 文字以上入らない | 手動 |
| AC-ID-09-M | 更新日・年会費を未入力で保存でき、詳細に「未設定」と出る | 手動 |
| AC-ID-10-M | API を止めた状態（`make down`）で名義を追加すると「オフラインです」が出て、UI の値が巻き戻る | 手動 |

### 4.4 T3（申込 + ツアー/公演）

| AC-ID | 受入基準 | 検証 |
|---|---|---|
| AC-AP-01-T | `ApplicationResponse` + `[Tour]` + `[EventEntity]` の join で `tourID`/`eventID` から表示名が解決される。対応する event が無い場合は `nil` を返し、空文字を作らない | `DomainTests` |
| AC-AP-02-T | `ApplicationDraft` → `CreateApplicationRequest` で `companions` に `id` と `position`（0 起点連番）が入る | `DomainTests` |
| AC-AP-03-T | `companions` の `identity_id` 重複が送信前に除去される | `DomainTests` |
| AC-AP-04-T | `event_date` が nil の申込が、公演日ソートで末尾に来る | `DomainTests` |
| AC-AP-05-T | ページング反復が `has_more == false` で止まり、20 ページで打ち切って `truncated = true` を立てる | `DomainTests`（`ApplicationRepository` のフェイクで検証） |
| AC-AP-06-M | 申込を追加すると DB に入り、再起動後も残る。ツアーが新規なら `tours` に 1 件増える | 手動（`make up` + psql or 再起動） |
| AC-AP-07-M | 既存ツアー名をサジェストから選んで申込を追加すると、**同じツアーにグルーピングされる**（ツアーが増えない） | 手動 |
| AC-AP-08-M | ステータスを「当選」に変えると再起動後も当選のまま。**落選に戻しても座席が消えない** | 手動（`docs/05` R3-3） |
| AC-AP-09-M | 座席をインライン編集して保存すると再起動後も残る | 手動 |
| AC-AP-10-M | ホームの 3 指標が実データに追随する（名義数 / 30日以内更新 / 当落発表待ち）。**日付基準が「今日」になっている**（2026-07-31 固定でない） | 手動（Q12） |
| AC-AP-11-M | API を止めた状態で申込一覧を開くと、既に読み込んだ内容が消えずエラーバーが出る | 手動 |
| AC-AP-12-M | `rep_membership_id` を送っていない（常に null） | 実装 grep + 手動 |

### 4.5 T4（共有リンク管理・オーナー側）

| AC-ID | 受入基準 | 検証 |
|---|---|---|
| AC-SH-01-T | `ShareScopeSelection.identitySummary` から作った `CreateShareRequest` に `scope_id` / `permission` キーが**存在しない** | `DomainTests` |
| AC-SH-02-T | `ACC-` 形式でないアカウント ID が送信前に弾かれる（`^ACC-[0-9A-F]{6}$`） | `DomainTests` |
| AC-SH-03-T | `ShareResponse` の DTO に `token` / `url` フィールドが定義されていない（型として持てない） | `DomainTests` + 実装 grep |
| AC-SH-04-T | `permission` を省略すると `read`、`.write` を選ぶと `"write"` が送られる。**未知値を作れる経路が無い**（enum） | `DomainTests` |
| AC-SH-05-T | `PLAN_LIMIT_SHARE_WRITE` が `.planLimitShareWrite(limit:current:)` に写り、`details` 欠落でもクラッシュしない | `DomainTests` |
| AC-SH-06-M | ツアー表から**「閲覧のみ」/「編集も許可」を選んで**共有リンクを作成でき、URL がコピーできる。`GET /v1/shares` に 1 件出る | 手動 |
| AC-SH-07-M | 共有中のツアー行に **`閲覧 N 回 ・ 編集 M 回`** が出る（`view_count` / `edit_count`） | 手動 |
| AC-SH-08-M | 「共有を停止」で `is_active` が false になり、表示が「共有終了」に変わる | 手動 |
| AC-SH-09-M | 2 本目の共有リンクを作ろうとすると「無料プランで作れる共有リンクは 1 本までです」が出る | 手動 |
| AC-SH-10-M | **4 公演以上あるツアーで「編集も許可」を選ぶと** `PLAN_LIMIT_SHARE_WRITE` の文言が出る。**iOS 側で事前に 3 をハードコードして弾いていない**（押せて 403 を文言化する） | 手動 + 実装 grep（IOS-4） |
| AC-SH-11-M | 共有プレビューの履歴公開トグルが `PATCH /v1/identities/:id` に届き、再起動後も残る | 手動 |
| AC-SH-12-M | **オーナー側のツアー表は常にローカルデータを描く**（共有ペイロードを取りに行かない）。共有先が編集した内容は「最新を取得」= `GET /v1/applications` の再取得で反映される | 手動 |
| AC-SH-13 | `TourShareStore` の UserDefaults 永続化（`TourShareStore.swift:56-88`・`149-153`）が**消えている** | `grep` |

### 4.5b T4b（共有ボード・受け取り側）

| AC-ID | 受入基準 | 検証 |
|---|---|---|
| AC-SB-01-T | `permission: "read"` のペイロードで `item_key` / `rev` / `editable` が無くてもデコードでき、`handle` が `nil` になる（**`editable ?? true` にしない**） | `DomainTests`（§4.8 P1） |
| AC-SB-02-T | `SharedItemHandle` は `itemKey` / `rev` / `editable` が揃ったときだけ生成され、片方欠けは `nil`（不整合状態を作れない） | `DomainTests`（P2） |
| AC-SB-03-T | `SharedItemChange` から作った body が **`rev` + (`status` か `seat` の少なくとも一方)** を必ず含み、3 キー以外を含まない | `DomainTests` |
| AC-SB-04-T | `seat` の「送らない」「`null` を送る」「空文字を送る」の 3 状態が JSON で区別される（空文字を `null` に丸めない） | `DomainTests`（P5） |
| AC-SB-05-T | `CONFLICT` + `details.current` が `.shareItemConflict(current:)` に格上げされる。`details` が読めなければ `.conflict` に留まる | `DomainTests` |
| AC-SB-06-T | 汎用エラーマッパー（`ErrorEnvelope`）は `.shareItemConflict` を**返さない**（格上げは `RemoteSharedBoardRepository` のみ） | `DomainTests` + 実装 grep |
| AC-SB-07-M | write リンクの URL をアプリで開くと共有ボードが表示され、状況と座席を編集できる | 手動 |
| AC-SB-08-M | read リンクを開くと**編集 UI が出ない**（タップしても何も起きない） | 手動 |
| AC-SB-09-M | `editable: false` の行は編集 UI が出ない。無理に叩いた場合は「この行は編集できません」（**理由を推測して説明しない**） | 手動 |
| AC-SB-10-M | 2 つのボードから同じ行を編集すると、後の方に「他の人が先に更新しました」が出て、**その行だけ**最新値で描き直される（全体再取得しない） | 手動（`rev` 409） |
| AC-SB-11-M | オーナー側で共有を停止した後にボードを操作すると「この共有は終了しました」になり、**保存されていた token が Keychain から消える** | 手動 |
| AC-SB-12-M | 編集後にオーナー側で「最新を取得」すると、その変更が申込一覧に反映される | 手動（往復確認） |
| AC-SB-13-M | ボードを開いたことで**自分のアカウントがログアウトしない**（未ログイン状態でも、ログイン状態でも） | 手動。**`PublicApiClient` を使っていない場合ここで落ちる** |
| AC-SB-14 | 共有 token が `print` / `Logger` / UserDefaults に出ていない。Keychain の service 名が自分の refresh token と**別** | `grep` + レビュー |
| AC-SB-15 | `SharedBoardItem` から `ApplicationEntry` / `Identity` への変換コードが**存在しない**（別系統の型として扱う） | `grep`（§4.8 P6） |

### 4.6 全タスク共通の完了ゲート（`CLAUDE.md`）

```bash
# iOS ビルド
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build

# 純粋関数テスト（Q13 で新設）
cd meigicho/Packages/Core && swift test
cd meigicho/Packages/Domain && swift test
```

BE は変更しないので `apps/api` のゲートは走らせない（走らせても影響が無いことの確認にはなる）。

---

## 5. エッジケースの実装割り当て

`requirements.md` §5 の各ケースをどのタスクが実装するか。**取りこぼし防止のため明示する。**

| ケース | 担当 |
|---|---|
| E-1 空データと読み込み失敗の区別 | T0（`LoadState`）+ 各タスクの画面 |
| E-2 `CONFLICT` 409 | T2 / T3 |
| E-3 削除済み名義を参照する申込 | T3（`rep_identity_id` が `identities` に無い場合の表示） |
| E-4 サーバー側の `rep_membership_id` 自動クリア | T3（PATCH レスポンスをそのまま反映） |
| E-5 並行 401 で refresh 1 回 | T1 |
| E-6 refresh 失効 → サイレントログアウト | T1 |
| E-7 オフライン書き込み | T0（`AppError.offline`）+ 各タスクの UI |
| E-8 `event_date` null | T0（型）+ T3（ソート・表示） |
| E-9 4,000 件超の打ち切り | T3 |
| E-10 タイムゾーン | T0（`APIDateFormat`） |
| E-11 共有リンクの期限切れ | T4（オーナー側の表示）/ T4b（`SHARE_INVALID` での token 破棄） |
| E-12 未知 enum 値のフォールバック | T0（`AppError` / マッパー） |
| **E-13** パスワード変更/リセット後のトークン全件失効 | **T1b**（返ってきたペアの保存 + 他端末のサイレントログアウト） |
| **E-14** Google サインインのユーザーキャンセル | **T1**（エラー扱いしない） |
| **E-15** 共有ボードの `rev` 競合（同時編集） | **T4b**（その行だけ再描画） |
| **E-16** 未ログイン状態で共有ボードだけを使う | **T4b**（ログインゲートを迂回する導線。`PublicApiClient` を使うので Bearer 不要） |
| **E-17** レート制限 429 | T1b（認証系）/ T4b（ボード編集 60 回/分）。**自動リトライしない** |

---

## 6. リスクと止めどころ

| # | リスク | 検知 | 対応 |
|---|---|---|---|
| R1 | T0 で 14 画面のコンパイルエラーが想定より膨らむ | T0 のビルドが通らない | **画面のロジックを書き換えて逃げない。** 型変更は `contract-mapping.md` §3 が正。追従が困難なら planner に差し戻す |
| ~~R2~~ | ~~Q4（nonce）の判断が覆り BE 変更が要る~~ | — | **解消。Q4 は「平文送信」で確定**し、BE（Apple / Google とも平文比較）と一致。**iOS 実装エージェントは引き続き `apps/api` を触らない** |
| R3 | Sign in with Apple / **Google** が Apple Developer・**Google Cloud** の設定なしでは検証できない | T1 の手動確認 | Apple: Capability（Sign in with Apple）を `project.yml` に追加。Google: **OAuth クライアント ID（iOS 種別）の作成と、その ID を BE の `GOOGLE_CLIENT_IDS` に設定**が前提。**設定できない場合は「AC-GG-03〜06 は未検証」と正直に報告する**（rule 07 カバレッジの正直さ）。推測で「動くはず」と書かない |
| R4 | Swift 6 strict concurrency で Store の `@unchecked Sendable` が破綻 | ビルド警告/エラー | `@MainActor @Observable` への移行を第一選択。`@unchecked` を**新規に増やさない**（NFR-1） |
| R5 | T3 の join（applications × tours × events）が N+1 を作る | 実装レビュー | 一覧は 3 本のリスト API を各 1 回だけ叩き、辞書に畳んで join する。`GET /v1/events/:id` の単発は「手元に無い event」のときだけ |
| ~~R6~~ | ~~共有ボード撤去がユーザーの期待と食い違う~~ | — | **解消。Q7 は「撤去しない」で確定**し、BE に write 権限が実装済み。T4b で `PATCH /public/shares/:token/items/:item_key` に接続する |
| **R7** | **共有ボードが `ApiClient`（認証あり）経由で実装され、401 で自分のアカウントがログアウトする** | AC-SB-13-M / レビュー | **`PublicApiClient` を T0 で先に作り**、T4b には「`ApiClient` / `TokenStore` を参照しない」を制約として書き写す（`contract-mapping.md` §5.1）。レビュー観点にも入れる。**本 rev で最も事故りやすい箇所** |
| **R8** | Google の自前 OAuth 実装（§7.2）が想定より難しい / Google 側の仕様変更で壊れる | T1 の AC-GG-03〜04 が通らない | 影響を `Network/GoogleSignInService.swift` **1 ファイルに閉じる**設計にし、詰まったら **`GoogleSignIn-iOS`（SPM）への差し替え**に切り替える。その場合 `requirements.md` NFR-6（依存追加ゼロ）の改訂が要るので **planner に差し戻す**（実装者が独断で SDK を足さない） |
| **R9** | `POST /v1/auth/password` / `password/reset` 成功時に返るトークンペアの**保存漏れ**で、変更した本人がログアウトする | AC-EM-08-M | T1b のプロンプトに A5 / A6（`contract-mapping.md` §4.1）を書き写す。**204 だと思い込んで戻り値を捨てない** |
| **R10** | T1 の scope 肥大（Apple + Google + ゲート + Keychain + 401 直列化）で 1 タスクが破綻する | T1 の完了報告が曖昧 | **T1 / T1b に分割済み**（本 rev）。それでも溢れるなら T1 を「基盤 + Apple」「Google」に再分割して planner に差し戻す |
| **R11** | 共有ボードのエントリポイント（Universal Links）が未整備で、受け取り側がアプリに入れない | T4b の AC-SB-07-M | **今回はカスタムスキーム + URL 貼り付けまで**（§7.7 Q16）。Universal Links は roadmap 1-7（Next.js 共有 Web）と同時に別計画 |

---

## 7. ハンドオフ（委譲プロンプト案）

rule 06 の 7 要素に沿う。**サブエージェントはコンテキストゼロで起動する**ので、絶対パスと決定事項を書き写すこと。

### 7.1 T0 — `swift-developer`（model: opus）

```
まず /Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md を読み、従ってください。

【目的/背景】
iOS クライアントを NestJS API に接続する準備として、Network パッケージ新設・Domain 型の契約合わせ・
Store 分割・ファイル分割を行う。これは後続 4 タスク（認証/名義/申込/共有）を並列化するための土台であり、
このタスク自体はネットワーク通信を一切行わない。**振る舞いを変えないこと**が最重要。

【対象】
リポジトリ: /Users/yuyamorishita/オタ活アプリ
編集対象: meigicho/ 配下（Core / Domain / DesignSystem / Features / App / project.yml、新規 Packages/Network）
**apps/api は一切触らない。**

【必読（この順で）】
1. /Users/yuyamorishita/オタ活アプリ/docs/plans/ios-network-integration/plan.md §3（T0 の作業内容）
2. /Users/yuyamorishita/オタ活アプリ/docs/plans/ios-network-integration/contract-mapping.md
   §2（日付・UUID・エラー変換）§3（Domain 型の before→after）§5（Repository protocol）
3. /Users/yuyamorishita/オタ活アプリ/.claude/rules/feedback_review_patterns.md の IOS-1〜IOS-5

【やること】plan.md §3.1〜§3.6 を上から順に。各項目は検証可能な単位です。
【従うべき既存例】
- JST 固定カレンダーの作り方: meigicho/Packages/Core/Sources/Core/DateFormatting.swift:4-8
- @Observable Store の書き方: meigicho/Packages/Domain/Sources/Domain/AppDataStore.swift:4-21
- Package.swift の書式: meigicho/Packages/Domain/Package.swift
- UUIDv7 の実装: docs/05-ios-client.md §2.4（そのまま採用してよい）

【制約・やらないこと】
- 第三者パッケージを追加しない（NFR-6）。Keychain も Security フレームワーク直叩き
- Features から Network を import しない（IOS-5）。Domain に URLSession/Security/SwiftData を import しない
- 401 リトライは実装しない（T1 の担当。TODO(T1) コメントを残す）
- SwiftData / オフラインキュー / ペイウォール / 通知はスコープ外
- Features のファイル分割は機械的に。ロジックを書き換えない
- Models.swift の型変更は contract-mapping.md §3 が正。独自判断で増減させない

【完了条件】
1. xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
     -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/meigicho-build \
     CODE_SIGNING_ALLOWED=NO build が BUILD SUCCEEDED
2. cd meigicho/Packages/Core && swift test / cd meigicho/Packages/Domain && swift test が green
3. plan.md §4.1 の AC-N-01-T〜AC-N-08-T をテストとして実装済み（Red→Green の順で）
4. シミュレータで 14 画面が従来と同じサンプルデータで表示される（AC-N-09-M）
5. grep -rn "import Network" meigicho/Packages/Features が 0 件

【報告フォーマット】日本語で
① 変更・新規ファイル一覧（絶対パス）
② 実行した検証コマンドと結果（AC-ID ごとの合否）
③ 残課題・未検証項目（「未調査」を隠さない）
④ contract-mapping.md と食い違う実装をした箇所があれば file:line で列挙
```

### 7.2 T1 — `swift-developer`（model: opus）: 認証基盤 + Apple + Google

T0 完了後に単独で発行。7.1 と同じ骨格で、以下を差し替える。

- **目的**: 認証基盤（Keychain・401 自動 refresh の直列化・ログインゲート）+ **Sign in with Apple と Google の 2 方式**
- **必読**: `contract-mapping.md` §4.1 / §4.1.1、`questions-requirements.md` **Q4 / Q5 / Q6**、
  および **`docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` §1**
- **前提の明記（プロンプト冒頭に必ず書く）**:
  > `questions-requirements.md` Q3（Google / メールログイン UI の撤去）は**ユーザー判断で覆り、「撤去しない」に確定**しました。
  > Google とメール+パスワードを**追加**します。既存の `GoogleSignInButton` / `LoginDivider`（DesignSystem）は**削除しないでください**。
  > メール+パスワードは **T1b の担当**です。T1 では Apple と Google だけを実装してください。
- **契約の書き写し（必ず指示文に入れる）**:
  - `POST /v1/auth/apple` の req は `{ identity_token, nonce? }`、**`POST /v1/auth/google` は `{ id_token, nonce? }`。キー名が違う**
  - **nonce は認可リクエストに設定したのと同じ文字列をそのまま送る。sha256 しない**（BE は Apple / Google とも平文比較 — `apps/api/src/auth/apple-token.verifier.ts:123-129`）
  - 両者のレスポンスは**完全に同形**（`AuthSessionResponse`）。DTO を共通化してよい
  - `POST /v1/auth/refresh` は **回転式**。レスポンスの `refresh_token` を必ず保存し直す。旧トークンは即失効
  - access token TTL は 3600 秒（`apps/api/src/auth/auth.service.ts:18`）
  - `AUTH_GOOGLE_INVALID` 401 は `.googleSignInFailed`。**`AUTH_APPLE_INVALID` に丸めない**
- **Google の取得方法（決定事項。§7.2.1 を全文プロンプトに書き写す）**
- **やらないこと**: `apps/api` を触らない。**第三者パッケージを追加しない**（詰まったら planner に差し戻す — R8）。メール+パスワードを実装しない（T1b）。オンボーディング画面を作らない（`is_new` は無視）
- **完了条件**: 共通ゲート + AC-AUTH-01〜10 / AC-GG-01〜07。手動確認は `make up` した状態で実施し、**各 AC の結果を個別に書く**。
  Google の OAuth クライアント ID が未取得で AC-GG-03〜06 を実行できない場合は「**未検証**」と明記する（推測で「通るはず」と書かない）

#### 7.2.1 Google の `id_token` 取得方法 — **決定事項**（`[要確認]` Q15）

**採用: `ASWebAuthenticationSession` + PKCE の自前実装（第三者 SDK を追加しない）。**

実装の骨格（`Packages/Network/Sources/Network/GoogleSignInService.swift` 1 ファイルに閉じる）:

| 手順 | 内容 |
|---|---|
| 1 | `Core.PKCE` で `codeVerifier` / `codeChallenge`（S256）、`Core.Nonce` で `nonce`、別途 `state` を生成 |
| 2 | 認可 URL を組み立てる: `https://accounts.google.com/o/oauth2/v2/auth?client_id=<iOS OAuth client id>&redirect_uri=<reversed client id>:/oauth2redirect&response_type=code&scope=openid%20email%20profile&code_challenge=<challenge>&code_challenge_method=S256&nonce=<nonce>&state=<state>` |
| 3 | `ASWebAuthenticationSession(url:callbackURLScheme: <reversed client id>)` を開く。`prefersEphemeralWebBrowserSession = false` |
| 4 | コールバックから `code` を取り出す。**`state` が一致しなければ拒否**。`error=access_denied` はユーザーキャンセルとして扱い、エラー表示しない |
| 5 | `POST https://oauth2.googleapis.com/token` に **`application/x-www-form-urlencoded`** で `code` / `client_id` / `code_verifier` / `redirect_uri` / `grant_type=authorization_code` を送る（**iOS クライアントに client_secret は無い**）。**このリクエストは JSON ではないので `ApiClient` を通さず、このファイル内で `URLSession` を直接使う** |
| 6 | レスポンスの `id_token` を**加工せず**、手順 1 の `nonce` と一緒に `POST /v1/auth/google` へ送る |

設定（`project.yml` / `Info.plist` / BE env）:

- `CFBundleURLTypes` に reversed client ID（`com.googleusercontent.apps.<...>`）を登録
- `GOOGLE_IOS_CLIENT_ID` を `Info.plist` から読む（`API_BASE_URL` と同じ経路）
- **この client ID が BE の `GOOGLE_CLIENT_IDS` に含まれていること**が動作条件。含まれないと `AUTH_GOOGLE_INVALID` になるが、iOS 側からは原因が見えない（AC-GG-05-M）

**採用理由**:

1. **必要なのは一度きりの `id_token` だけ。** セッション維持は自前 JWT が担うので、SDK の主機能（トークン保管・自動更新・One Tap）が丸ごと不要
2. **`ASWebAuthenticationSession` はシステムフレームワーク**（Sign in with Apple で既に `AuthenticationServices` を import している）。RFC 8252「ネイティブアプリは外部ブラウザを使う」に沿った Google 公認の経路で、埋め込み WebView 禁止ポリシーにも抵触しない
3. **`SWIFT_STRICT_CONCURRENCY: complete` との相性。** `GoogleSignIn-iOS` は ObjC 依存（AppAuth / GTMAppAuth / GTMSessionFetcher）を 3 つ引き連れ、非 `Sendable` 型と completion handler を `@MainActor` で包む作業が発生する
4. **リポジトリの既存方針との一致。** BE も依存を減らす方向で `jose` を選んでいる（`backend-domain-modules/plan.md` §3.1）。`requirements.md` NFR-6（依存追加ゼロ）を維持できる
5. **純関数部分（PKCE・URL 組み立て・コールバック解析）が `swift test` で検証できる**（AC-N-11-T / AC-GG-01-T / AC-GG-02-T）

**却下案: `GoogleSignIn-iOS`（SPM）を追加する。**
利点は「Google 公式・ブランド準拠のボタン・仕様変更への追従」。却下理由は上記 1〜4。
ただし **R8 の通り、自前実装が詰まったらこちらに切り替える**。切り替えは `requirements.md` NFR-6 の改訂を伴うので
**実装者の独断ではなく planner に差し戻す**。影響範囲を `GoogleSignInService.swift` 1 ファイルに閉じておくのはそのため。

**[要確認]**: この判断（自前実装 / SDK）はユーザーに確認したい。`questions-requirements.md` に Q15 として追記し `[Answer]` を得ること。

### 7.3 T1b / T2 / T3 — `swift-developer` ×3（**同一メッセージで並列発行**）

**発行前に必ず**「同時に触らせないファイル」（§2.1）を 3 つのプロンプト全部に書き写す。

#### T1b（opus）: メール+パスワード + プロフィール

- **必読**: `contract-mapping.md` §4.1（特に落とし穴 A1〜A11）/ §4.2、`api-contract-delta.md` §1・§2
- **前提の明記**:
  > `questions-requirements.md` Q3 は覆り、**メール+パスワード認証を追加**します。`AuthStore` / `SignInView` は
  > T1 が Apple + Google まで実装済みです。**その上に追記**してください（作り直さない）。
- **契約の書き写し（必ず入れる。ここを外すと事故る）**:
  - `POST /v1/auth/register` は **201**、`login` / `password/reset` は 200。`reset-request` は **202 + ボディ無し**
  - **`POST /v1/auth/password` と `POST /v1/auth/password/reset` は成功時にサーバーが「その user の refresh token を全件失効」させ、新しいペアを返す。返ってきたペアで Keychain を必ず上書きすること。捨てると自分自身が次の refresh でログアウトする**（R9）
  - `POST /v1/auth/password` は **Bearer 必須**。他の 5 本は Public
  - `login` の 401 は未登録 / パスワード誤り / パスワード未設定を**区別しない**。iOS も区別して表示しない
  - `reset-request` は登録の有無に関わらず常に 202。UI は「**登録されていれば送信しました**」と書く（「送信しました」と断定しない）
  - `code` は `^\d{8}$`。`password` は **8〜128 文字・文字種要件なし**（独自の複雑さルールを足さない = IOS-4）
  - `auth_providers` に `"email"` が**含まれるときだけ**「パスワードを変更」を出す。無いのに叩くと `FORBIDDEN` 403
  - レート制限あり（`reset-request` は 3 回/15 分）。429 は `.rateLimited`。**自動リトライしない**
- **やらないこと**: `apps/api` を触らない。§2.1 の T1b 行以外のファイルを触らない。Apple / Google の実装に手を入れない
- **完了条件**: 共通ゲート + AC-EM-01〜14 / AC-ME-01〜04

#### T2 / T3

- **T2（sonnet）**: identities + memberships。必読 `contract-mapping.md` §4.3〜4.4。
  契約の書き写し: **`member_no` / `member_no_cipher` は送れない（400）。`member_no_last4` は 1〜4 文字の英数のみ**。
  `history_visible` の既定は `false`。`PLAN_LIMIT_IDENTITY` 403 の `details` は `{limit, current}`。
  編集してよいのは §2.1 の T2 行のファイルのみ。
- **T3（opus）**: applications + tours/events + home。必読 `contract-mapping.md` §4.5〜4.6。
  契約の書き写し: **`POST /v1/tours` / `POST /v1/events` は存在しない**。tour/event は `POST /v1/applications` の
  find-or-create でしか作れない。`cursor` は opaque で解釈しない。`companions` は 0〜3 件、`id` 必須、`position` は 0 起点。
  `rep_membership_id` は常に null を送る。編集してよいのは §2.1 の T3 行のファイルのみ。

T2 / T3 に共通で書く一文:
> `ApplicationListView.swift` の共有関連セクション（`TourShareStore` を参照する箇所）は **T4 の担当**です。
> 今回は既存のまま残し、コンパイルが通る最小限の追従に留めてください。

### 7.4 T4 — `swift-developer`（model: opus）: 共有リンク管理（オーナー側）

- **必読**: `contract-mapping.md` §4.7、`api-contract-delta.md` §3
- **前提の明記（プロンプト冒頭）**:
  > `questions-requirements.md` Q7（共有ボード編集の撤去）は**ユーザー判断で覆り、「撤去しない」に確定**しました。
  > BE に共有 write 権限が実装済みです。ただし **T4 はオーナー側（リンクの発行・状態表示・失効）だけ**を担当します。
  > **共有ボードそのもの（受け取り側の編集画面）は T4b の担当**なので作らないでください。
- **契約の書き写し**:
  - `token` / `url` は `POST /v1/shares` のレスポンスにのみ存在。`GET /v1/shares` は `token` を返さない
  - `permission` は **`"read"` / `"write"`、省略時 `"read"`**。未知値は 400（黙って `read` に落とさない = BE-2）
  - **`"write"` は `scope_type: "tour"` のみ**。`identity_summary` と組み合わせたら 400
  - **`"write"` は公演数上限あり（free = 3 公演 / plus = 無制限）。超過は `PLAN_LIMIT_SHARE_WRITE` 403 + `details: {limit, current}`。iOS 側で 3 をハードコードして事前に弾かない**（IOS-4）。押させて 403 を文言化する
  - `GET /v1/shares` の items に **`edit_count` / `last_edited_at`** が増えている
  - **発行後に `permission` を変更する API は無い**。変更 = `DELETE` して再発行
- **やること**:
  1. `TourShareStore` → `ShareLinkStore` に改名し、UserDefaults 永続化（`TourShareStore.swift:56-88`・`149-153`）を削除して `ShareRepository` 経由にする
  2. ツアー行の共有 UI: 未共有 / 共有中（`閲覧 N 回 ・ 編集 M 回` + 期限）/ 共有終了 の 3 状態
  3. **共有作成時に「閲覧のみ」/「編集も許可」を選ばせる**（`ShareRecipientsView` に追加）
  4. **オーナー側のツアー表はローカルデータ一本**にする。共有ペイロードを取りに行かない。既存の `cycleSharedStatus` / `saveSharedSeat` 呼び出しは **T3 が接続した通常の申込 PATCH 経路**（`ApplicationStore`）に置き換える
  5. `SharePreviewView` の履歴公開トグルを `PATCH /v1/identities/:id` に接続
- **やらないこと**: `apps/api` を触らない。`AppRoute.swift` に新ケースを足さない（T4b が触る）。`SharedBoardRepository` を実装しない（T4b）
- **完了条件**: 共通ゲート + AC-SH-01〜13

### 7.4b T4b — `swift-developer`（model: opus）: 共有ボード（受け取り側）

- **必読**: `contract-mapping.md` **§4.8 と §5.1（全文）**、`api-contract-delta.md` §4
- **前提の明記（プロンプト冒頭）**:
  > このタスクは **Bearer 認証を使わない経路**を実装します。共有リンクを受け取った人は
  > 自分のアカウントでログインしていない前提です。**資格情報は URL 中の token だけ**です。
- **最重要の制約（太字で 3 回書く価値がある）**:
  > **`ApiClient` / `TokenStore` を絶対に参照しないでください。** `Network/PublicApiClient.swift`（T0 が作成済み）だけを使います。
  > 理由: `ApiClient` は 401 で refresh を試み、失敗するとサイレントログアウトします。**共有ボードを開いただけのユーザーが
  > 自分のアカウントからログアウトさせられる事故**になります（AC-SB-13-M）。
- **契約の書き写し**:
  - `GET /public/shares/:token` と `PATCH /public/shares/:token/items/:item_key`。**`/v1` プレフィックスは付かない**
  - `item_key` / `rev` は **不透明値。解釈も生成もしない**。GET で受け取った `rev` をそのまま PATCH に返す
  - `permission == "read"` のとき `item_key` / `rev` / `editable` は**キーごと存在しない**。`editable ?? true` にしない
  - PATCH の body は **`rev` 必須 + `status` / `seat` の少なくとも一方**。**3 キー以外を送ったら 400**
  - `seat` は「送らない」「`null`」「空文字」の 3 状態を区別する（**空文字を `null` に丸めない**）
  - エラーの判定順序（`api-contract-delta.md` §4 の表）: `SHARE_INVALID` 404 → `FORBIDDEN` 403 → 400 → `SHARE_INVALID` 404 → `FORBIDDEN` 403 → `CONFLICT` 409 → `RATE_LIMITED` 429
  - **`CONFLICT` 409 は `details.current = { status, seat, rev }` を持つ。その行だけ再描画し、ボード全体を再取得しない**
  - `editable: false` の**理由（プラン超過 / 非公開名義）はサーバーが区別しない**。iOS も推測して説明しない
  - レート制限 60 回/分。**自動リトライしない**
- **やること**:
  1. `RemoteSharedBoardRepository`（`PublicApiClient` 使用）+ DTO（`contract-mapping.md` §4.8）
  2. **`CONFLICT` → `.shareItemConflict(current:)` の格上げはこのファイル内だけ**で行う（汎用マッパーは `.conflict` のまま）
  3. `SharedBoardTokenStore`（Keychain・**自分の refresh token とは別 service 名前空間**・複数本保持・`SHARE_INVALID` で破棄）
  4. `SharedBoardStore`（Domain）+ `SharedBoardView`（Features/SharedBoard）: 表・状況トグル・座席インライン編集
  5. エントリポイント（§7.7 Q16 の決定に従う）: `App/DeepLinkRouter.swift` + `MeigichoApp.swift` に `.onOpenURL` 1 行 + `AppRoute` に `.sharedBoard(token:)` を追加
- **やらないこと**: `apps/api` を触らない。`SharedBoardItem` を `ApplicationEntry` / `Identity` に変換しない。Universal Links 対応をしない（§7.7）。共有ボードの内容をローカル永続化しない（token だけ保存）
- **完了条件**: 共通ゲート + AC-SB-01〜15

### 7.7 共有ボードのエントリポイント — **決定事項**（`[要確認]` Q16）

受け取った人がどうやってアプリでボードを開くか。

**採用: カスタムスキーム `meigicho://share/<token>` + アプリ内の「共有リンクを開く」（URL 貼り付け）の 2 経路。**

- Universal Links（`https://share.example.com/s/<token>` のタップでアプリが開く）は **`apple-app-site-association` の配置が必要**で、
  それは `docs/09-roadmap.md` 1-7（Next.js 共有 Web ビュー・5 人日）の一部。**本計画のスコープ外**（`contract-mapping.md` §6 B6）
- 当面、共有先はブラウザで Web ビューを見るか、URL をアプリに貼り付けてボードを開く
- **オーナー自身はボードを開く必要が無い**（自分のデータをネイティブに見ているため）。ボードは受け取り側専用

**[要確認]**: Universal Links を本計画に含めるかをユーザーに確認したい。含める場合は BE / インフラ側（AASA 配信）の作業が発生するため、
**別計画**（`ios-universal-links` または roadmap 1-7 と統合）を先に立てる。`questions-requirements.md` に Q16 として追記し `[Answer]` を得ること。

### 7.5 T5 — `code-reviewer`（model: opus・**別セッションで**）

```
【差分範囲】meigicho/ 配下の全変更（T0〜T4b）+ meigicho/project.yml + docs/plans/ios-network-integration/
【保存先】/Users/yuyamorishita/オタ活アプリ/docs/plans/ios-network-integration/review.md
【必読】
- docs/plans/ios-network-integration/contract-mapping.md（iOS 側契約の正。特に §5.1）
- docs/plans/backend-domain-modules/api-contract.md（基底契約）
- docs/plans/backend-auth-and-shares-extension/api-contract-delta.md（認証拡張 + 共有 write。食い違いはこちらが優先）
- .claude/rules/feedback_review_patterns.md（特に IOS-1〜IOS-5）
【重点観点】
1. **未認証経路の隔離（最優先）**: 共有ボード（/public/*）が PublicApiClient だけを使っているか。
   ApiClient / TokenStore を参照していないか。**401 で自分のアカウントがログアウトする経路が無いか**（R7）
2. **パスワード変更・リセット後のトークン保存**: 返ってきた TokenPair を Keychain に上書きしているか（R9）
3. API 契約 3 層の一致: Prisma ↔ NestJS presenter ↔ iOS DTO。**フィールドの取りこぼし**を DTO 単位で突き合わせる（IOS-2）。
   特に Apple の identity_token と Google の id_token のキー名取り違え、edit_count / last_edited_at / permission の欠落
4. 未知値の黙殺（BE-2 の iOS 版）: 未知 error code / 未知 enum / 未知 auth_provider が既知値に丸められていないか。
   **permission や status を黙って既定値に落としていないか**
5. `editable ?? true` になっていないか（read リンクで編集 UI が出る事故）
6. 依存方向: Features → Network の直接参照、Domain への URLSession/Security/SwiftData 混入（IOS-5）
7. 死にコード: TourShareStore の UserDefaults 永続化、SampleData の実行時参照が残っていないか（IOS-1）
8. トークンの扱い: Keychain のアクセシビリティ、共有 token と refresh token の名前空間分離、
   ログ・print への漏洩（id_token / code / token）、並行 refresh の直列化
9. 縦串: UI → Store → Repository → Client が各機能で通っているか（IOS-3）
10. 仕様にない制約: 名義上限（3）や write 共有の公演数上限（3）を iOS 側でハードコードしていないか（IOS-4）。
    パスワードに独自の複雑さルールを足していないか
【スコープ外（指摘不要）】
SwiftData / オフライン書き込み / 同期エンジン / ペイウォール UI / StoreKit / AdMob / ローカル通知 /
統計画面 / Next.js 共有 Web / APNs / Universal Links / .xcconfig の環境分離
※ Google・メール認証は **スコープ内**（Q3 が覆ったため。旧版の記載から変更）
```

---

## 8. 完了後にやること（実装完了の定義に含める）

1. `docs/05-ios-client.md` の更新
   - §1 の「Phase 0 は SwiftData が SSoT」の位置づけを実態に合わせる（Phase 1 は Network 直結、SwiftData は次計画）
   - §1 のディレクトリ図を実装に合わせる（`Network` に `PublicApiClient` / `GoogleSignInService` が入る）
   - `AppRoute` / `AppSheet` のサンプルコード（§3）が実装と食い違っているので実装に合わせる（`.sharedBoard(token:)` が増える）
   - **画面対応表（§3）に `SignInView` / `PasswordChangeView` / `PasswordResetView` / `SharedBoardView` を追加**
2. `CLAUDE.md` の更新
   - 「既知の未整備」の「iOS 側（Network/DataStore）は未追従」を実態に更新
   - 「検証ゲート」に `swift test`（Core / Domain）を追加（Q13 の回答が Yes の場合）
3. `docs/04-api.md` に `api-contract-delta.md` §5 の E1〜E11 が反映済みか確認する（BE 側タスクだが、iOS 追従の前提なので確認は残す）
4. `docs/09-roadmap.md` との対応の記録: 本計画は Phase 1 の
   **1-2（Sign in with Apple と自前 JWT）の iOS 側** / **1-6（共有リンク発行）の iOS 側** / **1-8（共有プレビュー画面）** に相当する。
   **1-3（同期エンジン 8 人日）・1-4（初回移行 2 人日）・1-7（Next.js 共有 Web + Universal Links 5 人日）は未着手のまま**であることを明記する
5. 次計画の起票:
   - `docs/plans/ios-offline-sync/`（SwiftData + `/v1/sync` の BE 追加を含む）
   - `docs/plans/share-web-and-universal-links/`（roadmap 1-7。共有ボードの URL タップ導線をここで完成させる — §7.7 / `contract-mapping.md` §6 B6）
6. **`docs/08-compliance-risk.md` の委託先一覧に Resend を追記**（`CLAUDE.md` の「本番運用前に必須」）。
   パスワードリセットのメール送信は T1b で iOS から叩くようになるため、法務確認の未了を放置しない
