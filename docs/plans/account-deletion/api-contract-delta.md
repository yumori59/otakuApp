# API 契約差分 — account-deletion

**本書は次の 2 本への追記差分である。基底のファイルは書き換えない。**

1. `docs/plans/backend-domain-modules/api-contract.md`（基底契約）
2. `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md`（認証拡張・共有 write の差分）

実装エージェント（`nest-developer` / `swift-developer`）は **基底契約 + 上記差分 + 本書**を契約の正として扱い、
ここに書かれたパス・メソッド・JSON キー・ステータス・エラーコードを勝手に変えない。変更が必要なら実装を止めて planner に差し戻す（rule 02）。

**後方互換**: 既存エンドポイントの変更は無い。**新規 1 ルートの追加のみ**。

---

## 0. 共通規約への追加

### エラーコード

**新規追加なし。** 本ルートは既存コードのみを使う。

| code | HTTP | 本ルートでの意味 |
|---|---|---|
| `VALIDATION_ERROR` | 400 | パスワード認証を持つアカウントで `password` が未指定 / 空 / 文字列でない |
| `UNAUTHENTICATED` | 401 | Bearer 欠落・access token 不正/期限切れ |
| `AUTH_CREDENTIALS_INVALID` | 401 | `password` 不一致（メッセージは `POST /v1/auth/password` と同じ固定文字列 `"invalid email or password"`） |
| `NOT_FOUND` | 404 | 対象ユーザーが既に存在しない（2 回目の削除・並行削除の後発） |
| `RATE_LIMITED` | 429 | 10 回 / 5 分（userId 単位）を超過 |
| `INTERNAL` | 500 | 削除トランザクションの失敗（**部分削除は残らない**） |

### レート制限（既存表に追加）

| ルート | 上限 | カウント単位 |
|---|---|---|
| `DELETE /v1/me` | 10 回 / 5 分 | userId（`POST /v1/auth/password` と同じ `AUTH_USER` throttler を再利用。バケットはルート単位で独立） |

### 環境変数（Q2 = A を採用する場合のみ・新規）

| 変数 | 既定 | 用途 |
|---|---|---|
| `APPLE_CLIENT_ID` | 無し | Sign in with Apple の client_id（iOS の bundle id）。失効 API の `client_id` |
| `APPLE_TEAM_ID` | 無し | client_secret JWT の `iss` |
| `APPLE_KEY_ID` | 無し | client_secret JWT の `kid` |
| `APPLE_PRIVATE_KEY` | 無し | .p8 秘密鍵（PEM 文字列。改行は `\n` エスケープ可） |

**いずれか 1 つでも未設定なら失効呼び出しをスキップする**（warn ログのみ）。**削除自体は必ず成功させる**。
`docker-compose.yml` の `api.environment` と `apps/api/.env.example` の双方に追加する（`config/env-coverage.spec.ts` の対象）。
※ `.env.example` はエージェントが書けない（deny 設定）ため、ユーザーの手動追記が必要。

---

## 1. `DELETE /v1/me` — 認証必須（新規）

**基底契約 §2「Me（プロフィール / アカウント）」に追加**する 3 本目のルート。

```json
// req（ボディ全体が任意。両キーとも省略可）
{
  "password": "correct horse battery",
  "apple_authorization_code": "c1a2b3..."
}
```

```
// 204 No Content（ボディ無し）
```

### リクエスト

| キー | 型 | 必須条件 |
|---|---|---|
| `password` | string | **`users.password_hash` が非 null のユーザーでは必須**。それ以外は無視される（送っても 400 にしない） |
| `apple_authorization_code` | string | 常に任意。Apple サインインの `ASAuthorizationAppleIDCredential.authorizationCode` を UTF-8 文字列にしたもの。**Q2 = A のときのみ意味を持つ** |

- ボディ自体が空（`{}` / body 無し）でもよい。Apple / Google のみのアカウントはこれで削除できる
- **DTO で `password` に長さ下限を掛けない**（`LoginDto` と同じ判断。旧ポリシーのアカウントを 401 と区別させない）。検証は `@IsString()` + 非空のみ
- `password` の必須判定は **UseCase 側**（DB の `password_hash` を見ないと判定できないため）。欠落時は `VALIDATION_ERROR` 400
- **対象ユーザーは常に Bearer の `sub`。** ボディ・クエリ・パスでユーザーを指定する手段を持たない（BE-4）

### レスポンス

- **204 No Content**（`GET/PATCH /v1/me` と違い body を返さない）
- 冪等ではない: 削除済みユーザーへの再実行は `NOT_FOUND` 404

### 副作用（契約として保証する範囲）

1. 次の全行が**物理削除**される（ソフトデリート済みの行も含む）:
   `application_companions` / `applications` / `memberships` / `identities` / `events` / `tours` / `share_links` / `device_tokens` / `refresh_tokens` / `password_reset_codes` / `entitlements` / `profiles` / `users`
2. 削除後、その user の refresh token はすべて無効。`POST /v1/auth/refresh` は `AUTH_REFRESH_INVALID` 401
3. 削除後、その user が発行した共有リンクは `GET /public/shares/:token` / `PATCH /public/shares/:token/items/:item_key` ともに **`SHARE_INVALID` 404**
4. **access token は失効しない**（署名検証のみのため最大 TTL = 既定 3600 秒は Guard を通過する）。クライアントは 204 受領後にただちに破棄すること
5. 同じ Apple ID / Google アカウント / メールアドレスで**再登録できる**（`is_new: true` の新規ユーザーになる）。旧データは復元されない
6. （Q2 = A のとき）`apple_authorization_code` が渡され、かつ Apple の鍵 4 変数が設定済みなら、削除成功後に Sign in with Apple の失効 API を呼ぶ。**結果はレスポンスに影響しない**

### エラー例

```json
// 400（password 必須のアカウントで未指定）
{ "code": "VALIDATION_ERROR", "message": "password is required for this account", "request_id": "..." }
```

```json
// 401（password 不一致）
{ "code": "AUTH_CREDENTIALS_INVALID", "message": "invalid email or password", "request_id": "..." }
```

```json
// 404（既に削除済み）
{ "code": "NOT_FOUND", "message": "user not found", "request_id": "..." }
```

---

## 2. 既存レスポンスの変更

**無し。** `GET /v1/me` の `user.auth_providers`（`["apple"|"google"|"email"]`）を
クライアントが「パスワード入力欄を出すか」の判定に使う。**新しい判定用フィールドは追加しない**。

| クライアント側の分岐 | 判定 |
|---|---|
| パスワード入力を要求するか | `auth_providers` に `"email"` が含まれるか（= iOS の `UserProfile.hasPasswordLogin`） |
| Apple の再サインインで `authorization_code` を取るか（Q2 = A） | `auth_providers` に `"apple"` が含まれるか |
| サブスク解約案内を出すか（Q6 = A） | `entitlement.plan == "plus"` または `entitlement.in_grace_period == true` |

---

## 3. iOS 側マッピング（`docs/plans/ios-network-integration/contract-mapping.md` への追記差分）

### 3.1 Repository protocol（`Domain/Repositories/Repositories.swift`）

`AuthRepository` に 1 メソッド追加する（**既存メソッドのシグネチャは変えない**）:

```swift
/// `DELETE /v1/me`。204。**成功したらトークンとローカル状態を必ず破棄する**。
/// - password: `auth_providers` に "email" がある場合のみ渡す（nil ならキー自体を送らない）
/// - appleAuthorizationCode: Apple 失効用（Q2 = A のときのみ。nil ならキーを送らない）
func deleteAccount(password: String?, appleAuthorizationCode: String?) async throws
```

- `ProfileRepository` ではなく **`AuthRepository`** に置く。セッション破棄と不可分であり、`AuthStore` から呼ぶため
- 実装は `Network/Remote/RemoteAuthRepository.swift`。`ApiClient.sendVoid(.versioned(.delete, "/me", body: ...))`
- `InMemoryAuthRepository`（`Domain/Preview/InMemoryRepositories.swift`）にも実装を足す（Preview / テスト用）

### 3.2 DTO（`Network/DTO/AuthEmailDTO.swift` に追加）

```swift
struct DeleteAccountRequest: Encodable {
    let password: String?
    let appleAuthorizationCode: String?
    enum CodingKeys: String, CodingKey {
        case password
        case appleAuthorizationCode = "apple_authorization_code"
    }
}
```

- `JSONEncoder` の既定（`encodeIfPresent`）により **nil のキーは送信されない**。`keyEncodingStrategy` は設定しない（§1.1 の方針）
- 両方 nil のときも `{}` を送ってよい（BE はボディ空を許容する）

### 3.3 エラーマッピング

**新規追加なし。** 既存の `contract-mapping.md` §2.3 の表をそのまま使う。文脈による文言のみ定義する:

| `code` | `AppError` | アカウント削除画面での文言 |
|---|---|---|
| `AUTH_CREDENTIALS_INVALID` | `.credentialsInvalid` | 「パスワードが違います」 |
| `NOT_FOUND` | `.notFound` | 「このアカウントは既に削除されています」（表示後にログアウト処理を実行する） |
| `RATE_LIMITED` | `.rateLimited` | 「試行回数が上限に達しました。しばらく待ってからお試しください」（**自動リトライしない**） |
| `.offline` / `.timeout` / `.server` | 既存 | 「削除できませんでした。通信状況を確認してもう一度お試しください」（**ログアウトしない**） |

`NOT_FOUND` だけは例外的に「削除済み」とみなしてローカルクリアまで進める（サーバー上に残っていないため）。
