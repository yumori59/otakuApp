# review — account-deletion（第三者レビュー / rule 04）

- 対象: `DELETE /v1/me`（T-BE1）+ Apple トークン失効（T-BE2）+ iOS 削除導線（T-IOS1 / T-IOS2 / T-IOS2b）
- 契約の正: `docs/plans/account-deletion/api-contract-delta.md` / `requirements.md` / `plan.md` §3.2
- レビュー実施日: 2026-08-06（実装者とは別セッション）
- リポジトリは git 管理外のため、差分ではなく計画に列挙されたファイル一式を対象に読み合わせた

## レビュー結果サマリ

- 重大: 2 件
- 中: 4 件
- 軽微/提案: 6 件

### 検証ゲート実行結果（レビュアーによる再実行）

| コマンド | 結果 |
|---|---|
| `cd apps/api && npx tsc --noEmit` | クリーン（出力なし） |
| `cd apps/api && npm test` | 68 suites / 747 tests 中 **746 passed・1 failed**。失敗は `auth/password.hasher.spec.ts` の `AC-EP-02`（5s タイムアウト）。**単体再実行では 9/9 passed（0.7s）で、本変更とは無関係な負荷依存のフレーク**（軽微-6） |
| `cd apps/api && npm run build` | 成功（`nest build`） |
| `xcodebuild ... build` | **BUILD SUCCEEDED** |
| `cd meigicho/Packages/Domain && swift test` | 141 tests / 0 failures |
| `cd meigicho/Packages/Network && swift test` | 143 tests / 0 failures |

---

## 重大 (Must Fix)

### 重大-1 Apple 失効 API に `authorization_code` を直接投げており、失効が成立しない可能性が高い

`apps/api/src/auth/apple-token.revoker.ts:68-73`

```ts
const body = new URLSearchParams({
  client_id: credentials.clientId,
  client_secret: createClientSecret(credentials),
  token: authorizationCode,
  token_type_hint: 'authorization_code',
});
```

Apple の `POST https://appleid.apple.com/auth/revoke` が受け付ける `token` は **`refresh_token` または `access_token`** で、
`token_type_hint` の許容値も `refresh_token` / `access_token` の 2 値である。`authorization_code` をそのまま送ると
`invalid_request` / `invalid_grant` 系の 4xx が返り、実装はベストエフォートなので **warn ログだけ出して 204 を返す**（`apple-token.revoker.ts:83-87`）。
つまり **失効は永久に成功しないまま、成功したように見える**（`plan.md` §4 のコードブロック自体が同じ誤りを含んでいるため、実装は plan に忠実である点は補足しておく）。

App Store Guideline は Sign in with Apple 利用アプリのアカウント削除でトークン失効を要求しているため、
このままだと T-BE2 の目的（Guideline 対応）を満たさない。

**修正案**（契約・plan の改訂が必要なので planner へ差し戻す想定）:

1. `POST https://appleid.apple.com/auth/token` に `grant_type=authorization_code` / `code` / `client_id` / `client_secret` を送って `refresh_token` を得る
2. 得た `refresh_token` を `token_type_hint=refresh_token` で `/auth/revoke` に送る
3. 1 が失敗した場合も従来どおり warn だけ（ベストエフォートは維持）
4. `apple-token.revoker.spec.ts:123-138` の期待値（`token_type_hint === 'authorization_code'`）も併せて更新する

※ 「実 Apple API への疎通確認」はスコープ外だが、本件は疎通ではなく**プロトコル（パラメータ仕様）の誤り**なのでスコープ内として指摘する。着手前に Apple の最新ドキュメント（Revoke Tokens）で許容値を再確認すること。

### 重大-2 Apple 再認可コーディネーターが解放され得る（Apple ユーザーの削除ボタンが無反応になり得る）

`meigicho/Packages/Features/Sources/Features/Account/AppleReauthorization.swift:27-36`
`meigicho/Packages/Features/Sources/Features/Account/AccountDeleteView.swift:175`

```swift
// AccountDeleteView.swift:175
switch await AppleReauthorizationCoordinator().requestAuthorizationCode() {
```

```swift
// AppleReauthorization.swift:28-35
await withCheckedContinuation { continuation in
    self.continuation = continuation
    let request = ASAuthorizationAppleIDProvider().createRequest()
    let controller = ASAuthorizationController(authorizationRequests: [request])
    controller.delegate = self                       // weak
    controller.presentationContextProvider = self    // weak
    controller.performRequests()
}
```

- `ASAuthorizationController.delegate` / `presentationContextProvider` は **weak**
- `AppleReauthorizationCoordinator` は `AccountDeleteView.submit()` の**式内テンポラリ**で、強参照の持ち主がいない
- `controller` もクロージャ内ローカルで、コールバックまでの間の強参照が実装側に無い

Swift の ARC はオブジェクト寿命を「最後の使用まで」しか保証しないため、`performRequests()` 直後にコーディネーター（および controller）が解放されると
delegate コールバックが呼ばれず、`CheckedContinuation` が**永久に再開されない**。その結果 Apple ユーザーが「アカウントを削除する」を押しても
`submit()` が suspend したまま何も起きない（`auth.isBusy` もまだ false なので UI 上は完全に無反応）。
シミュレータでの実タップ確認が未実施（既知）なので、**現状は再現性を確認できないまま出荷リスクを抱えている**。

**修正案**: コーディネーターと controller の強参照を明示的に保持する。

- `AccountDeleteView` に `@State private var appleReauth = AppleReauthorizationCoordinator()` を持たせて使い回す、もしくは
- `AppleReauthorizationCoordinator` 内に `private var controller: ASAuthorizationController?` と `private var selfRetain: AppleReauthorizationCoordinator?` を持ち、`requestAuthorizationCode()` で代入し `resume(_:)` で両方 nil にする（self-retain の解除漏れに注意）

併せて、コールバックが来ないケースに備えたタイムアウト（例: 60 秒で `.failed`）も検討に値する。

---

## 中 (Should Fix)

### 中-1 `NOT_FOUND` のとき契約が定める文言を表示していない

`meigicho/Packages/Features/Sources/Features/Account/AccountDeleteView.swift:188-190`

```swift
} catch AppError.notFound {
    // 既に削除済み
    finishAfterDeletion()
}
```

契約 `api-contract-delta.md` §3.3 は 「このアカウントは既に削除されています」**（表示後にログアウト処理を実行する）** と定めている。
実装は無言でシートを閉じるだけなので、`SignInView.swift:239-240` に用意した文言が**どこからも使われないデッドコード**になっている（IOS-1 の亜種）。

**修正案**: クリア実行前後にアラート or `ErrorBar` で文言を出してから閉じる。文言を出さない方針にするなら
`SignInView.swift:239-240` の分岐を削り、契約側も planner が更新する。

### 中-2 `AuthStore.deleteAccount` に二重実行ガードが無い（AC-AD-03-M が実質未検証）

`meigicho/Packages/Domain/Sources/Domain/AuthStore.swift:273-284`

```swift
public func deleteAccount(password: String?, appleAuthorizationCode: String?) async throws {
    isBusy = true
    defer { isBusy = false }
    ...
```

同ファイルの `performEmailSignIn`（`AuthStore.swift:299`）は `guard !isBusy else { throw EmailCredentialError.busy }`、
`performSignIn`（`AuthStore.swift:306`）は `guard !isBusy else { return }` を持つ。削除だけがガード無しで、
`requirements.md` AC-AD-03-M（「実行中は二重送信できない」）は **UI の `.disabled(!canExecute)` にのみ依存**している。
`AuthStoreTests.swift:170-231` にも `isBusy` を検証するケースが無く、AC-AD-03-M はテストでカバーされていない。

**修正案**: 既存 2 経路と同じく `guard !isBusy` を先頭に足し、`DomainTests` に「実行中の再入で repository が 2 回呼ばれない」テストを追加する。

### 中-3 Apple 再認可中は `isBusy` が false のままで、ボタン連打が防げない

`meigicho/Packages/Features/Sources/Features/Account/AccountDeleteView.swift:167-186`

`submit()` は `auth.deleteAccount` を呼ぶ**前**に Apple の再認可を待つ。この間 `auth.isBusy` は false なので
`canExecute`（`AccountDeleteView.swift:33-39`）が true のままとなり、システムシート表示前後の連打で
`ASAuthorizationController` が多重に走る余地がある（中-2 と合わさると削除リクエストの多重送信にもつながる）。

**修正案**: `@State private var isReauthorizing = false` を用意し `canExecute` に含める（`guard !isReauthorizing` + `defer`）。

### 中-4 削除画面で `VALIDATION_ERROR` の文言が未定義（プロフィール未取得時に迷子になる）

`meigicho/Packages/Features/Sources/Features/Account/SignInView.swift:237-245` / `AccountDeleteView.swift:35-39, 169`

確認方法の分岐は `profile.hasPasswordLogin` に依存する（`ProfileStore.swift:41` は profile 未ロード時に **false**）。
`AccountView` の `.task` で `profile.load()` に失敗した状態から削除シートを開くと、パスワードを持つユーザーにも
typed confirmation が出て `password: nil` で送信され、BE は契約どおり `VALIDATION_ERROR` 400（`delete-me.use-case.ts:34-36`）を返す。
このとき `AuthErrorText` に `(.validation, .deleteAccount)` の分岐が無いため、既定文言「入力内容を確認してください」だけが出て、
ユーザーは何を直せばよいか分からない。

**修正案**: (a) `AuthErrorText` に `(.validation, .deleteAccount)` → 「パスワードの入力が必要です。画面を開き直してください」を追加、
または (b) `AccountDeleteView` を開く前に `profile.profile == nil` なら再取得してから表示する。

---

## 軽微 (Nice to Have)

1. `meigicho/Packages/Features/Sources/Features/Account/AccountLocalDataClearing.swift:28` — 既定テーマ色 `"#0017C1"` のハードコードが `ThemeStore.swift:6` の既定値と二重管理。`ThemeStore` に `resetToDefault()` を足して呼ぶ方が平仄が良い。
2. `AccountLocalDataClearing.swift:26` — `appSettings.appDisplayName = nil` を直接代入している。`AppSettingsStore` には `setAppDisplayName(_:)`（`AppSettingsStore.swift:17`）があるので、クリア用 API（`clear()`）を生やす方が他ストア（`clear()` 実装済み）と揃う。
3. `apps/api/src/me/me.service.ts:177` — 削除ログが `account_deleted user_id=...` のみ。`NFR-AD-6` は「`userId` と `request_id`」を求めている（個人データを出していない点は要件どおり）。
4. `apps/api/src/me/use-cases/delete-me.use-case.ts:50` — `apple_authorization_code` があれば `auth_providers` に apple が無いユーザーでも失効を呼ぶ。実害は無いが、`user.appleSub`（`findUserForDeletion` が既に取得している）で絞ると無駄呼び出しが消える。※ ただし削除後に参照する値なので、事前に退避する実装になる点に注意。
5. `apps/api/.env.example` への `APPLE_TEAM_ID` / `APPLE_KEY_ID` / `APPLE_PRIVATE_KEY` 追記が未了（deny 設定によりエージェントが書けない既知事項）。`docker-compose.yml:41-44` には反映済みで `config/env-coverage.spec.ts` は通っている。ユーザーの手動追記が残課題。
6. `apps/api/src/auth/password.hasher.spec.ts:12` — フルスイート実行時に 5s タイムアウトで落ちることがある（単体では 0.7s で pass）。本変更とは無関係だが、`npm test` を完了ゲートにしている以上、`it(..., 15_000)` などで安定化しておくと良い。

---

## 良かった点

- **削除順序が契約どおり**。`me.service.ts:148-164` は `plan.md` §3.2 と完全一致し、`me.service.spec.ts:15-29` が順序配列を定数化して `toEqual` で固定、さらに `applications` < `identities` の位置関係を単独でも検証している（AC-AD-05・§1.1 の Restrict 回避が壊れたら必ず落ちる）。
- **ownerId スコープの検証が厳密**。`me.service.spec.ts:349-386` が全 13 件の `where` について「キーが 1 つだけ」「値が認証ユーザー ID」「モデルごとの `ownerId`/`userId`/`id` の使い分け」まで検証している（BE-4）。ボディに user 指定キーが無いことも `me.controller.spec.ts:123-131` で担保。
- **レイヤ規約の遵守**。UseCase は Prisma に触れず `MeService.findUserForDeletion`（`me.service.ts:130-136`）経由で users 行を読んでおり、ADR-009 / BE-3 を守った上で `AuthService` への依存も避けている（D6 どおり `PasswordHasher` だけを `AuthModule` から export）。
- **BE-6 の写像が正確**。P2025 のみ `NOT_FOUND` に写し、P2003 は握り潰さずそのまま投げる回帰テスト（`me.service.spec.ts:424-435`）まである。
- **秘密値の非漏洩テストが厚い**。`delete-me.use-case.spec.ts:246-284` は `message`/`stack`/`getResponse()` を連結して password と code の非混入を確認、`apple-token.revoker.spec.ts:224-257` は秘密鍵の各行と client_secret までログ非混入を確認している（NFR-AD-3）。
- **ES256 実装が正しい**。`apple-token.revoker.ts:130-137` が `dsaEncoding: 'ieee-p1363'` を指定して JWS 形式（r‖s）で署名しており、`apple-token.revoker.spec.ts:172-185` が実際に公開鍵で検証している。`\n` エスケープされた .p8 の受け入れ（`:108`）と 4 変数欠落時スキップも網羅。
- **ベストエフォート性が二重に担保**。`AppleSignInTokenRevoker` 自身が例外を投げない設計で、さらに UseCase 側でも try/catch（`delete-me.use-case.ts:50-60`）。削除失敗時は失効を呼ばないことまでテスト済み（`delete-me.use-case.spec.ts:225-233`）。
- **ローカルクリアの共通化**。`AccountLocalDataClearing`（新規）を削除と**ログアウト両経路**から呼び、`requirements.md` D4 が指摘した既存の取りこぼし（`AccountView.swift:122-129`）を是正している。`KeychainSharedBoardTokenStore` を触っていないのも仕様どおり。
- **ゲスト非表示は構造的に満たされている**。`AccountView.swift:31-33` がゲストなら `SignInView` に差し替わるため、削除導線（`:137`）に到達しない（E-10 / AC-AD-11-M）。
- 契約 3 層（Prisma ↔ DTO/Controller ↔ iOS DTO/Repository）のキー名・型・ステータスが一致。`DeleteAccountRequest` は `CodingKeys` で `apple_authorization_code` を明示し `keyEncodingStrategy` を使っていない（IOS-2）。Domain は Network を参照していない（IOS-5）。

---

## スコープ外（指摘対象外として確認のみ）

- 実 Apple API への疎通（鍵未設定のため未検証）／Apple 再認可の実機タップ確認 — 既知
- エクスポート導線（Q3 = A）／猶予期間付き削除（Q1）／`schema.prisma` 変更（D1 却下 B）／IAP 連携

---

## 再レビュー結果（修正差分）

- 対象: 初回レビュー（重大 2 / 中 4）の修正差分のみ
  - BE: `apps/api/src/auth/apple-token.revoker.ts` / 同 `.spec.ts` / `docs/plans/account-deletion/plan.md` §4
  - iOS: `AppleReauthorization.swift` / `AccountDeleteView.swift` / `AuthStore.swift` / `AuthStoreTests.swift` / `SignInView.swift`
- レビュー実施日: 2026-08-06（実装者とは別セッション）
- 判定: **重大 0 件**。初回指摘の重大-1 / 重大-2 / 中-1〜4 はすべて再現条件が解消していることを一次ソースで確認した

### レビュー結果サマリ

- 重大: 0 件
- 中: 1 件（今回の修正に伴って新たに生じた導線の詰まり）
- 軽微/提案: 4 件

### 検証ゲート実行結果（レビュアーによる再実行）

| コマンド | 結果 |
|---|---|
| `cd apps/api && npx tsc --noEmit` | クリーン（出力なし） |
| `cd apps/api && npm test` | **73 suites / 773 tests すべて pass**（3.1s）。初回レビューで観測した `password.hasher.spec.ts` のフレークも今回は発生せず |
| `cd apps/api && npm run build` | 成功（`nest build`） |
| `xcodebuild ... -derivedDataPath /tmp/meigicho-build build` | **BUILD SUCCEEDED**（`error:` 0 件） |
| `xcodebuild ... -derivedDataPath /tmp/meigicho-build-review2`（**新規 DerivedData**） | **BUILD FAILED**。失敗は全件 `RevenueCat` ターゲットの `compiling for iOS 13.0, but module 'Network' has a minimum deployment target of iOS 17.0`。**本差分とは無関係の既存問題**（軽微-4） |
| `swift test --package-path meigicho/Packages/Domain` | 162 tests / 0 failures |
| `swift test --package-path meigicho/Packages/Network` | 148 tests / 0 failures |

---

### 初回指摘の解消確認

#### 重大-1 Apple 失効の 2 段階化 → **解消**

- 1 段目 `apple-token.revoker.ts:107-119`: `POST /auth/token` に `client_id` / `client_secret` / `code` / `grant_type=authorization_code` のみ。`token` / `token_type_hint` は**混入していない**（`apple-token.revoker.spec.ts:179-180` が `toBeNull()` で固定）
- 2 段目 `apple-token.revoker.ts:145-157`: 1 段目の応答 JSON から取った `refresh_token` を `token` に、`token_type_hint='refresh_token'` で `POST /auth/revoke`。`spec.ts:194-199` が値の一致に加えて **body に `authorization_code` が現れないこと**まで検証している
- ベストエフォート維持: 1 段目が非 2xx（`:121-126`）/ `refresh_token` 欠落（`:128-135`）なら 2 段目を呼ばずに return、それ以外の例外は `revokeAuthorizationCode` の try/catch（`:91-95`）で握る。`spec.ts:202-232, 293-339` が「例外にせず」「2 段目を呼ばない」の両方を確認
- 秘密値ログ: 応答本文は一切ログに出さず、ステータスのみ（`:122-124, 161-163`）。例外は `errorLabel`（`:219-222`）で `name` だけ。`spec.ts:342-395` が `AUTHORIZATION_CODE` / `REFRESH_TOKEN` / `ACCESS_TOKEN` / 秘密鍵各行 / `client_secret` の非混入を検証
- `plan.md:130-141` も 2 段階へ改訂され、初版が誤っていた旨まで明記されている（契約と実装の乖離なし）

#### 重大-2 コーディネーターの早期解放 → **解消**

強参照は 3 重で、どれか 1 つでも `resume` まで生き残れば継続が再開される。解放タイミングを追跡した結果:

1. `AppleReauthorization.swift:41` `self.selfRetain = self` — 自己参照。`resume(_:)`（`:52-62`）でのみ解除
2. 同 `:45` `self.controller = controller` — `ASAuthorizationController` の強参照（delegate / presentationContextProvider が weak であることへの対処）
3. `AccountDeleteView.swift:31, 234` `@State private var appleReauthorization` — SwiftUI ストレージ側の保持。`defer`（`:229-232`）で await 完了後に解放

`resume(_:)` の実装が正しい。`let retained = selfRetain` → `selfRetain = nil` → `withExtendedLifetime(retained) { continuation.resume(...) }` の順で、**自己参照を切った瞬間に self が解放されて `continuation.resume` の実行中に死ぬ**という最後の穴も塞いである（`:56-61`）。加えて `requestAuthorizationCode()` は `AppleReauthorizationCoordinator` の async メソッドなので、呼び出し側 async フレームが `self` を呼び出し期間中保持する。二重起動は `:36-39` の `guard self.continuation == nil` で `.failed` に落とす。

#### 中-1 `NOT_FOUND` 文言 → **解消**

`AccountDeleteView.swift:215-218` で `alreadyDeletedMessage` に `AuthErrorText.message(for: .notFound, context: .deleteAccount)`（= `SignInView.swift:242-243` の「このアカウントは既に削除されています」）を入れ、`:108-119` のアラートで表示 → **OK でのみ** `finishAfterDeletion()`（ローカルクリア + dismiss）を実行する。契約 `api-contract-delta.md:166`「表示後にログアウト処理を実行する」の順序どおりで、`SignInView` の文言もデッドコードでなくなった。
`AuthStore.deleteAccount` 側は従来どおり `.notFound` でもローカルセッションを消してから throw する（`AuthStore.swift:281-283`、`AuthStoreTests.swift:214-232`）ため、アラート表示中に既にサインアウト済みという状態は契約どおり。`AccountView.swift` の `.sheet` は `auth.isGuest` 分岐の**外側**に付いているので、`signedOut` に変わってもシートは維持されアラートは表示される（読み合わせで確認）。

#### 中-2 二重実行ガード → **解消**

`AuthStore.swift:274` に `guard !isBusy else { throw EmailCredentialError.busy }` を追加。`performEmailSignIn`（`:299`）と同じ扱いで平仄も取れている。
テストは見せかけでない: `AuthStoreTests.swift:236-263` が `AsyncGate`（`:351-` の決定的な同期プリミティブ、sleep 不使用）で 1 回目をサーバー応答待ちに固定し、`isBusy == true` を確認したうえで 2 回目が `.busy` で弾かれること・`repository.deleteAccountCalls.count == 1` であることを検証している。フェイク側も「門で止めるのは 1 回目だけ」（`:341-344`）とすることで、**ガードを外すとハングではなく失敗する**ように書かれている（ガード削除で赤くなることを意図した設計）。
なお `.busy` は `AccountDeleteView.swift:219-221` の汎用 catch で「処理中です。しばらくお待ちください」（`AuthStore.swift:429-430`）として表示され、削除文脈でも意味が通る。

#### 中-3 再認可中の連打 → **解消**

`AccountDeleteView.swift:26, 40, 42-48` で `isReauthorizing` を導入し `isWorking = auth.isBusy || isReauthorizing` を `canExecute` とボタン `.disabled` に反映。`submit()` 先頭にも `guard !isWorking`（`:194`）があり、`.disabled` だけに依存していない。`requestAppleAuthorizationCode()`（`:227-236`）は `isReauthorizing = true` をフラグ設定 → `defer` で確実に false に戻す。`View` は `@MainActor` なので、フラグ設定は最初の実サスペンド前に完了する。進行中表示も「確認しています…／削除しています…」に出し分けている（`:74-82`）。

#### 中-4 `VALIDATION_ERROR` 文言 → **解消（提案 (a)(b) 両方を実施）**

- (a) `SignInView.swift:239-241` に `(.validation, .deleteAccount)` →「パスワードの入力が必要です。画面を開き直してください」
- (b) `AccountDeleteView.swift:103-107` の `.task` で `profile.profile == nil` のとき `profile.load()` を実行し、そもそも `hasPasswordLogin` が false に倒れないようにした

---

## 中 (Should Fix)

### 中-R1 Apple のコールバックが返らないと、シートが「閉じる」でも閉じられなくなる

`meigicho/Packages/Features/Sources/Features/Account/AccountDeleteView.swift:100`（`.disabled(isWorking)`）
`meigicho/Packages/Features/Sources/Features/Account/AppleReauthorization.swift:34-50`

再認可はタイムアウトを持たない。`ASAuthorizationController` が delegate を一度も呼ばない事象（重大-2 で問題にしていた事象そのもの）が起きると、
`continuation` は再開されず `isReauthorizing` が true のまま固定され、

- 「アカウントを削除する」は `canExecute == false` で押せない
- **「閉じる」も `.disabled(isWorking)` で押せない**（今回 `isWorking` を導入した副作用。修正前は `auth.isBusy` のみだった）
- `selfRetain` によりコーディネーターは永久にリークする

スワイプでのシート破棄（`.interactiveDismissDisabled` は付いていないので有効）でしか抜けられない。発生確率は低いが、初回レビューで提案したタイムアウトを入れれば構造的に消える。

**修正案**: `requestAuthorizationCode()` に 60 秒程度のタイムアウトを持たせ、期限到達で `resume(.failed)`（`selfRetain` / `controller` も解放）する。あるいは最低限「閉じる」は `auth.isBusy` のみで disable し、再認可中は閉じられるようにする。

---

## 軽微 (Nice to Have)

1. `apps/api/src/auth/apple-token.revoker.ts:118, 156` — 5 秒タイムアウトが 2 段になったため、`DELETE /v1/me` の応答は最悪 +10 秒引きずられる（失効は 204 応答**前**に同期実行するため）。レイテンシ NFR は無いので許容だが、合計上限を持たせるか失効をレスポンス後に回す余地がある。
2. `meigicho/Packages/Features/Sources/Features/Account/AppleReauthorization.swift:55` — `resume(_:)` で delegate コールバック実行中に `self.controller = nil` している。実運用ではフレーム側が controller を保持しているので問題にならない一般的な書き方だが、self に対して行った `withExtendedLifetime` 相当の配慮は controller には無い。
3. `meigicho/Packages/Features/Sources/Features/Account/AccountDeleteView.swift:31, 234` — `@State` 保持とコーディネーター内 `selfRetain` は保険として重複している（意図的な二重化。コメントもある）。将来どちらかを削るときは、削ってよい理由を必ずコメントに残すこと。
4. **（既存問題・本差分と無関係）** 空の DerivedData から `xcodebuild` すると `RevenueCat` ターゲットが `compiling for iOS 13.0, but module 'Network' has a minimum deployment target of iOS 17.0` で 50 件失敗する。ローカルパッケージ名 `Network` が Apple の `Network` フレームワークと衝突し、iOS 13 ターゲットの RevenueCat がローカル `Network.swiftmodule` を拾うため。既存 DerivedData（`/tmp/meigicho-build`）では成功するので普段は表面化しないが、**CI を入れると必ず落ちる**。パッケージ名を `MeigichoNetwork` などに改名するか、RevenueCat 側の探索パスを切り分ける対応が別途必要（本機能のスコープ外）。
5. 初回レビューの軽微 1〜5（テーマ既定色の二重管理・`AppSettingsStore.clear()`・削除ログの `request_id`・`user.appleSub` での事前判定・`.env.example` 追記）は今回の差分では未着手。いずれも据え置きで問題ない。

---

## 良かった点

- **重大-1 の直し方が仕様に忠実**。`/auth/token` → `/auth/revoke` の 2 段化に加え、`plan.md:130-141` を「初版の記述が誤っていた」と明記して改訂しており、実装だけ直して計画が嘘のまま残る事態を避けている。
- **テストが本物**。`apple-token.revoker.spec.ts:179-180`（1 段目に `token` / `token_type_hint` が無いこと）と `:199`（2 段目の body に `authorization_code` が現れないこと）は、旧実装に戻すと必ず落ちる形で書かれている。`tokenResponse()`（`:78-88`）が Apple の実応答キー構成を模しており、`refresh_token` 欠落・非 JSON・4xx の各分岐も網羅。
- **ARC 対策の詰め方が丁寧**。`selfRetain` を解除してから resume する順序の危険性まで理解した上で `withExtendedLifetime` を挟んでおり（`AppleReauthorization.swift:56-61`）、単に強参照を足しただけの雑な修正になっていない。
- **`AsyncGate`（`AuthStoreTests.swift:351-`）が sleep なしの決定的同期**で書かれており、二重実行テストがフレークしない。フェイクが「2 回目は門で止めない」設計になっているので、ガードを外すとハングせず失敗する。
- **既存ロジックを壊していない**。削除順序（`me.service.ts`）・本人確認（`delete-me.use-case.ts:26-44`）・失効はベストエフォート（`:47-60`）・ローカルクリア共通化（`AccountLocalDataClearing`）はいずれも無改変で、BE 773 テストが全て緑。
- 中-4 は提案 (a)(b) の**両方**を実装しており、文言追加だけでなく発生条件自体（プロフィール未取得）も潰している。
