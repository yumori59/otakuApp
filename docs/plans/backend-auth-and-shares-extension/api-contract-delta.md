# API 契約差分 — backend-auth-and-shares-extension

**この文書は `docs/plans/backend-domain-modules/api-contract.md`（以下「基底契約」）への追記差分である。**
基底契約のファイルは書き換えない。実装エージェントは**基底契約 + 本差分**を契約の正として扱い、ここに書かれたパス・メソッド・JSON キー・enum 値を勝手に変えない。変更が必要なら実装を止めて planner に差し戻す。

**後方互換の原則**: 既存エンドポイントのリクエスト必須項目は増やさない。レスポンスはキーの**追加のみ**で、既存キーの削除・改名・型変更はしない。

---

## 0. 共通規約への追加

### エラーコード（基底契約 §0 の表に追加）

| code | HTTP | 使う場面 |
|---|---|---|
| `AUTH_GOOGLE_INVALID` | 401 | Google id_token の検証失敗（署名 / iss / aud / exp / nonce / 未知 kid — 理由は区別しない） |
| `AUTH_CREDENTIALS_INVALID` | 401 | メール+パスワードのログイン失敗、パスワード変更時の `current_password` 不一致 |
| `AUTH_RESET_CODE_INVALID` | 401 | パスワードリセットのコード検証失敗（未知 email / 誤コード / 期限切れ / 使用済み / 試行超過を**区別しない**） |
| `EMAIL_ALREADY_REGISTERED` | 409 | `POST /v1/auth/register` で `email` が既に登録済み |
| `PLAN_LIMIT_SHARE_WRITE` | 403 | `permission:"write"` の共有リンクを、プラン上限を超える公演数の tour に対して発行しようとした。`details: { limit, current }` |
| `RATE_LIMITED` | 429 | レート制限超過 |

- `FORBIDDEN` 403 の用途が増える（基底契約は「本計画では未使用の予定」と記載）: ①read 共有リンクへの書き込み ②`editable:false` の行への書き込み（`history_visible=false` **または**公演数上限の超過分。**理由は区別しない**）③パスワード未設定アカウントの `POST /v1/auth/password`
- `CONFLICT` 409 の用途が増える: 共有 item の `rev` 不一致（楽観ロック）
- `AllExceptionsFilter` は HTTP 429 を `RATE_LIMITED` に写す（`errorCodeFromStatus` に case 追加）

### enum 値（基底契約 §0 の表を更新）

| 対象 | 値 |
|---|---|
| `permission`（share） | `read` / `write` ← **`write` を追加** |

その他の enum に変更なし。`status`（application）は共有 write でも `draft` / `applied` / `won` / `lost` / `cancelled` の 5 値のみ。

### レート制限（新規）

| ルート | 上限 | カウント単位 |
|---|---|---|
| `POST /v1/auth/login` | 10 回 / 5 分 | 正規化 email |
| `POST /v1/auth/register` | 10 回 / 5 分 | 正規化 email |
| `POST /v1/auth/password` | 10 回 / 5 分 | userId |
| `POST /v1/auth/password/reset-request` | **3 回 / 15 分** | 正規化 email |
| `POST /v1/auth/password/reset` | **10 回 / 15 分** | 正規化 email |
| `PATCH /public/shares/:token/items/:item_key` | 60 回 / 分 | token |

超過時は `RATE_LIMITED` 429（envelope は共通）。`POST /v1/auth/apple` / `/google` / `/refresh` / `/logout` には適用しない（トークン検証自体が総当たり耐性を持つため）。

### 環境変数（新規）

| 変数 | 既定 | 用途 |
|---|---|---|
| `GOOGLE_CLIENT_IDS` | 無し（**必須**） | 受理する `aud` のカンマ区切りリスト（iOS クライアント ID / サーバークライアント ID） |
| `GOOGLE_ISSUER` | 未設定なら `https://accounts.google.com` と `accounts.google.com` の**両方**を受理 | 設定した場合はその値のみ受理 |
| `GOOGLE_JWKS_URL` | `https://www.googleapis.com/oauth2/v3/certs` | Google JWKS |
| `RESEND_API_KEY` | 無し | Resend の API キー。**本番で未設定ならリセットメール送信時に `INTERNAL` 500**（コードをログに落とさない）。非本番で未設定のときのみコンソール出力にフォールバックしてよい |
| `RESEND_FROM_EMAIL` | 無し | 送信元アドレス（例: `no-reply@example.com`）。Resend 側で検証済みドメインであること |

`docker-compose.yml` の `api.environment` と `apps/api/.env.example` に同時に追加する（`config/env-coverage.spec.ts`）。

---

## 1. Auth への追加

### `POST /v1/auth/google` — Public（新規）

```json
// req
{ "id_token": "eyJhbGciOi...", "nonce": "optional" }
```

```json
// 200 — POST /v1/auth/apple と完全に同形
{
  "access_token": "eyJhbGciOi...",
  "refresh_token": "dGhpcy1pcy...",
  "expires_in": 3600,
  "token_type": "Bearer",
  "user": {
    "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
    "account_id": "ACC-3F9A21",
    "display_name": null,
    "plan": "free",
    "is_new": true
  }
}
```

- リクエストキーは **`id_token`**（Apple は `identity_token`。Google SDK の命名に合わせる）
- `nonce` はリクエストが送ってきたときのみ検証する（Apple と同じく**サーバー側でハッシュしない**単純比較）
- `email` は id_token の `email_verified === true` のときだけ `users.email` に保存。既存ユーザーでは上書きしない
- エラー: `AUTH_GOOGLE_INVALID` 401 / `VALIDATION_ERROR` 400 / `INTERNAL` 500（`GOOGLE_CLIENT_IDS` 未設定）

### `POST /v1/auth/register` — Public（新規）

```json
// req
{ "email": "fan@example.com", "password": "correct horse battery" }
```

```json
// 201 — user.is_new は常に true。ボディ形状は /v1/auth/apple と同形
{
  "access_token": "eyJ...",
  "refresh_token": "dGhpcy1pcy...",
  "expires_in": 3600,
  "token_type": "Bearer",
  "user": {
    "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
    "account_id": "ACC-7C21A0",
    "display_name": null,
    "plan": "free",
    "is_new": true
  }
}
```

- `email`: `@IsEmail()`・255 文字以下。保存は元の値を `users.email`、`trim().toLowerCase()` を `users.email_normalized`
- `password`: **8〜128 文字**。文字種の複雑さ要件なし
- エラー: `EMAIL_ALREADY_REGISTERED` 409 / `VALIDATION_ERROR` 400 / `RATE_LIMITED` 429
- **201 Created**（Apple / Google / login は 200。register だけが新規リソース作成なので 201）

### `POST /v1/auth/login` — Public（新規）

```json
// req
{ "email": "fan@example.com", "password": "correct horse battery" }
```

- 200。ボディは `POST /v1/auth/apple` と同形で `user.is_new` は常に `false`
- エラー: `AUTH_CREDENTIALS_INVALID` 401 / `VALIDATION_ERROR` 400 / `RATE_LIMITED` 429
- **401 は未登録・パスワード誤り・パスワード未設定アカウントで区別しない**（message も同一固定文字列 `"invalid email or password"`）

### `POST /v1/auth/password` — **認証必須**（新規）

```json
// req
{ "current_password": "old one", "new_password": "a brand new one" }
```

```json
// 200 — refresh を全件失効させるため、新しいトークンペアを返す
{
  "access_token": "eyJ...",
  "refresh_token": "bmV3LXJlZnJlc2g...",
  "expires_in": 3600,
  "token_type": "Bearer"
}
```

- `POST /v1/auth/refresh` と同じ `TokenPairResponse` 形
- 成功時、**その user の既存 refresh token をすべて失効**させた上で新しい 1 本を発行する（他端末は次の refresh で `AUTH_REFRESH_INVALID` 401 → サイレントログアウト）
- `new_password` の制約は register と同一。`current_password === new_password` は 400
- エラー: `UNAUTHENTICATED` 401（Bearer 不正）/ `AUTH_CREDENTIALS_INVALID` 401（`current_password` 不一致）/ `FORBIDDEN` 403（`password_hash` が null = Apple / Google のみのアカウント）/ `RATE_LIMITED` 429

### `POST /v1/auth/password/reset-request` — Public（新規）

```json
// req
{ "email": "fan@example.com" }
```

- **202 Accepted / ボディ無し**。登録の有無・パスワード設定の有無に関わらず**常に同じ応答**（アカウント列挙を防ぐ）
- メールを送るのは「`email_normalized` が一致し、かつ `password_hash` が非 null」のユーザーだけ。Apple / Google のみのアカウントには送らない
- メール本文には **8 桁の数字コード**・有効期限（15 分）・心当たりが無ければ無視してよい旨を載せる。他の個人情報は載せない
- 発行時に同一ユーザーの未使用コードをすべて失効させる（有効なのは常に最新 1 本）
- メール送信に失敗しても **202 を返す**（応答で存在を漏らさない）。失敗はサーバーログに残す
- エラー: `VALIDATION_ERROR` 400（email 形式）/ `RATE_LIMITED` 429

### `POST /v1/auth/password/reset` — Public（新規）

```json
// req
{ "email": "fan@example.com", "code": "48210937", "new_password": "a brand new one" }
```

```json
// 200 — POST /v1/auth/login と同形（リセット後そのままログイン状態にする）
{
  "access_token": "eyJ...",
  "refresh_token": "dGhpcy1pcy...",
  "expires_in": 3600,
  "token_type": "Bearer",
  "user": {
    "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
    "account_id": "ACC-3F9A21",
    "display_name": null,
    "plan": "free",
    "is_new": false
  }
}
```

- `code`: **8 桁の数字**（`^\d{8}$`）。`new_password`: 8〜128 文字（register と同一）
- 成功時、同一 TX で ①パスワード更新 ②当該コードを使用済みに ③**その user の refresh token を全件失効** ④他の未使用コードも失効 — した上で新しいペアを発行する
- **失敗はすべて `AUTH_RESET_CODE_INVALID` 401**（未知 email / 誤コード / 期限切れ / 使用済み / 試行超過を区別しない。message も同一固定文字列 `"invalid or expired reset code"`）
- 誤コード 5 回で当該コードを失効させる（以後は正しいコードでも 401）
- エラー: `AUTH_RESET_CODE_INVALID` 401 / `VALIDATION_ERROR` 400 / `RATE_LIMITED` 429

**リセット token を返す代わりに 204 にする案は却下**: ユーザーが今まさに新パスワードを入力した直後であり、追加のログイン操作を求める意味が無い。リセットコードが漏れていた場合の被害は「新パスワードを知られている」ことと同じで、トークンを返しても増えない。

---

## 2. Me への変更（キー追加なし・値の導出のみ変更）

`GET /v1/me` の `user.auth_providers` の導出規則を更新する。**キー・型は不変。**

| 状態 | 現行 | 変更後 |
|---|---|---|
| `apple_sub` あり | `["apple"]` | `["apple"]` |
| `google_sub` あり | `["google"]` | `["google"]` |
| `password_hash` あり | （経路が無く発生しない） | `"email"` を含む |
| `apple_sub` + `password_hash` | — | `["apple","email"]` |
| どれも無いが `email` だけある | `["email"]` | `[]`（**判定を `password_hash` に変更**） |

順序は `apple` → `google` → `email` で固定。

---

## 3. Shares への追加

### `POST /v1/shares` — `permission` を受理（後方互換）

```json
// req（permission 以外は基底契約 §8 と同一）
{
  "scope_type": "tour",
  "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
  "permission": "write",
  "mask_member_no": true,
  "expires_at": "2026-08-31T00:00:00.000Z",
  "shared_with_account_ids": ["ACC-3F9A21"]
}
```

- `permission`: `"read"` / `"write"`。**省略時 `"read"`**（既存クライアントの挙動は変わらない）
- `"write"` は `scope_type: "tour"` のみ。`identity_summary` と組み合わせたら `VALIDATION_ERROR` 400
- 未知の値は `VALIDATION_ERROR` 400（BE-2。黙って `read` に落とさない）
- **`"write"` はどのプランでも発行できる。ただし公演数に上限がある**（Q3）:

| プラン | 1 本の write 共有に含められる公演数 |
|---|---|
| `free` | **3 件**（`EntitlementsService.shareWriteEventLimit` → `3`） |
| `plus` | 無制限（→ `null`） |

- 判定対象は対象 tour の **`events` のうち `deleted_at is null` の件数**（申込ゼロの公演も 1 件と数える）。超過していたら `PLAN_LIMIT_SHARE_WRITE` 403 / `details: { limit: 3, current: 8 }`
- `read` リンクはこの制限を受けない
- 同時有効リンク数の上限（`PLAN_LIMIT_SHARE`）は read / write を区別せず従来どおり数える
- **発行後に公演が増えた / プランが下がった場合**、リンクは有効のまま。公開ペイロード側で先頭 N 公演だけが `editable: true` になる（§4）
- 201 のボディは既存と同じキー構成（`permission` は既に含まれている）
- **発行後に `permission` を変更する API は提供しない**。変更したい場合は `DELETE /v1/shares/:id` → 再発行

### `GET /v1/shares` — items にキーを 2 つ追加

```json
{
  "items": [
    {
      "id": "018f3c2a-1111-7c90-9d2a-000000000001",
      "scope_type": "tour",
      "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
      "scope_name": "STELLARIS LIVE TOUR 2026",
      "permission": "write",
      "mask_member_no": true,
      "shared_with_account_ids": ["ACC-3F9A21"],
      "expires_at": "2026-08-31T00:00:00.000Z",
      "revoked_at": null,
      "view_count": 3,
      "last_viewed_at": "2026-08-02T10:00:00.000Z",
      "edit_count": 2,
      "last_edited_at": "2026-08-02T11:30:00.000Z",
      "created_at": "2026-08-01T00:00:00.000Z",
      "is_active": true
    }
  ]
}
```

追加は `edit_count`（number・既定 0）と `last_edited_at`（ISO8601 または null）のみ。`token` / `token_hash` を含めない規則は不変。

---

## 4. Public への追加

### `GET /public/shares/:token` — `permission` を追加 / write のとき item に handle を追加

`scope_type = "tour"` かつ `permission = "read"`（**現行と `permission` キー以外は同一**）:

```json
{
  "scope_type": "tour",
  "permission": "read",
  "tour": { "name": "STELLARIS LIVE TOUR 2026", "artist_name": "STELLARIS" },
  "generated_at": "2026-08-02T10:00:00.000Z",
  "items": [
    {
      "event_name": "大阪公演 Day1",
      "venue": "大阪城ホール",
      "event_date": "2026-08-20",
      "round_name": "FC1次",
      "rep_name": "自分",
      "rep_color": "#0017C1",
      "companions": ["妹"],
      "status": "applied",
      "seat": null
    }
  ]
}
```

`permission = "write"` のとき、**各 item にだけ `item_key` / `rev` / `editable` が増える**:

```json
{
  "scope_type": "tour",
  "permission": "write",
  "tour": { "name": "STELLARIS LIVE TOUR 2026", "artist_name": "STELLARIS" },
  "generated_at": "2026-08-02T10:00:00.000Z",
  "items": [
    {
      "event_name": "大阪公演 Day1",
      "venue": "大阪城ホール",
      "event_date": "2026-08-20",
      "round_name": "FC1次",
      "rep_name": "自分",
      "rep_color": "#0017C1",
      "companions": ["妹"],
      "status": "applied",
      "seat": null,
      "item_key": "b3RhLWtleS1zYW1wbGUx",
      "rev": "cmV2LXNhbXBsZQ",
      "editable": true
    },
    {
      "event_name": "大阪公演 Day2",
      "venue": "大阪城ホール",
      "event_date": "2026-08-21",
      "round_name": "FC1次",
      "rep_name": "非公開の名義",
      "rep_color": null,
      "companions": [],
      "status": "applied",
      "seat": null,
      "item_key": "cWlxLWtleS1zYW1wbGUy",
      "rev": "cmV2LXNhbXBsZTI",
      "editable": false
    }
  ]
}
```

| キー | 型 | 意味 |
|---|---|---|
| `permission` | `"read"` / `"write"` | 閲覧側が編集 UI を出すかの判定。**`identity_summary` スコープのペイロードにも付く**（常に `"read"`） |
| `item_key` | string（base64url 22 文字） | 書き込み対象の不透明ハンドル。**リンクごとに異なる**。`hmac_sha256(key=share_links.token_hash, msg="item:"+application.id)` を base64url して先頭 22 文字 |
| `rev` | string（base64url 16 文字） | 楽観ロックトークン。`hmac_sha256(key=share_links.token_hash, msg="rev:"+application.id+":"+application.updated_at.toISOString())` を base64url して先頭 16 文字 |
| `editable` | boolean | **次の 2 条件を両方満たすとき `true`**: ①代表名義の `history_visible` が `true` ②その公演が「公演順で先頭 N 件」に入っている（N = オーナーの `shareWriteEventLimit`。`null` なら無制限）。`false` の行は PATCH が 403 |

**`editable` の公演順**: `event_date asc nulls last, event_name asc`（`TourMatrixService` の既存の並びと同一）。同一公演に複数の申込がある場合、それらは同じ「1 公演」として数える。
**判定タイミング**: 発行時ではなく**閲覧・更新のたび**にオーナーの現在のプランで評価する。したがって公演の追加やプランのダウングレードに自動追従する。**理由（プラン超過か非公開名義か）はレスポンスから区別できない**（オーナーの課金状態を共有先に漏らさない）。

**不変条件（変えてはいけない）**: `item_key` / `rev` は内部 UUID・`updated_at` を復元できない。read リンクのペイロードにはこの 3 キーが**現れない**。

`scope_type = "identity_summary"` は `permission: "read"` が増えるだけで、他は現行どおり。

### `PATCH /public/shares/:token/items/:item_key` — Public（新規）

`/v1` プレフィックスは付かない（`app.setup.ts` の `GLOBAL_PREFIX_EXCLUDE` に追加）。

```json
// req（status / seat の少なくとも一方が必須。rev は必須）
{ "rev": "cmV2LXNhbXBsZQ", "status": "won", "seat": "1F A列 12番" }
```

```json
// 200 — 更新後の item 1 件（GET の items 要素と同形・新しい rev）
{
  "event_name": "大阪公演 Day1",
  "venue": "大阪城ホール",
  "event_date": "2026-08-20",
  "round_name": "FC1次",
  "rep_name": "自分",
  "rep_color": "#0017C1",
  "companions": ["妹"],
  "status": "won",
  "seat": "1F A列 12番",
  "item_key": "b3RhLWtleS1zYW1wbGUx",
  "rev": "bmV3LXJldi12YWx1ZQ",
  "editable": true
}
```

リクエスト制約:

| キー | 必須 | 制約 |
|---|---|---|
| `rev` | ○ | GET で受け取った値をそのまま返す |
| `status` | △ | `draft` / `applied` / `won` / `lost` / `cancelled`。未知値は 400 |
| `seat` | △ | 200 文字以下の文字列 または `null`。空文字は空文字として保存 |

- `status` と `seat` の**両方が無いボディは 400**
- **上記 3 キー以外を送ったら 400**（`forbidNonWhitelisted`）。`round_name` / `note` / `ticket_count` / `price_yen` / `companions` / 削除は共有先に開放しない

判定順序とエラー（**この順序が契約**）:

| # | 条件 | 応答 |
|---|---|---|
| 1 | トークンが未知 / 失効 / 期限切れ | `SHARE_INVALID` 404 |
| 2 | `permission !== "write"` | `FORBIDDEN` 403 |
| 3 | `scope_type !== "tour"`（DB 不整合） | `FORBIDDEN` 403 |
| 4 | ボディが不正 | `VALIDATION_ERROR` 400 |
| 5 | `item_key` が当リンクのどの item とも一致しない | `SHARE_INVALID` 404 |
| 6 | 対象行が `editable: false`（`history_visible=false` **または**公演数上限の超過分。**理由を区別しない**） | `FORBIDDEN` 403 |
| 7 | `rev` 不一致（同時更新） | `CONFLICT` 409 |
| 8 | レート超過 | `RATE_LIMITED` 429 |

`CONFLICT` 409 の envelope（`details` に現在値を入れて再描画できるようにする）:

```json
{
  "code": "CONFLICT",
  "message": "share item was updated by someone else",
  "details": {
    "current": { "status": "lost", "seat": null, "rev": "Y3VycmVudC1yZXY" }
  },
  "request_id": "018f3c2a-9999-7c90-9d2a-000000000001"
}
```

副作用:

- 成功時のみ `share_links.edit_count += 1` / `last_edited_at = now()`。**`view_count` は増やさない**
- 1〜8 のいずれかで失敗した場合、`applications` にも `share_links` にも書き込みを行わない
- レスポンスヘッダに `X-Robots-Tag: noindex, nofollow` を付ける（GET と同じ）

### CORS（基底契約 §8 の記述を訂正）

基底契約は「CORS は `CORS_ORIGINS` に対して `GET, OPTIONS` のみ」と書いているが、**実装（`main.ts:16`）は `enableCors({ origin })` のみでメソッドを制限していない**（Nest 既定で PATCH も許可されている）。本差分では契約文言を実装に合わせて **`GET, PATCH, OPTIONS`** と読み替える。`main.ts` は変更しない。

---

## 5. 基底契約に対する差分サマリ（実装後に `docs/04-api.md` へ反映する）

| # | 差分 | 後方互換 |
|---|---|---|
| E1 | `POST /v1/auth/google` を新設 | 追加のみ |
| E2 | `POST /v1/auth/register` / `POST /v1/auth/login` / `POST /v1/auth/password` を新設 | 追加のみ |
| E2b | `POST /v1/auth/password/reset-request` / `POST /v1/auth/password/reset` を新設 | 追加のみ |
| E3 | エラーコードを 6 つ追加、`FORBIDDEN` / `CONFLICT` の用途を拡張 | 追加のみ |
| E4 | `permission` enum に `write` を追加 | 既定は `read` のまま |
| E5 | `POST /v1/shares` が `permission` を受理（write は公演数上限あり） | 任意項目。省略時の挙動は不変 |
| E6 | `GET /v1/shares` items に `edit_count` / `last_edited_at` | キー追加のみ |
| E7 | `GET /public/shares/:token` に `permission` を追加 | キー追加のみ（**既存 spec の `toEqual` は要更新**） |
| E8 | write リンクの item に `item_key` / `rev` / `editable` | write リンクのみ。read の形は不変 |
| E9 | `PATCH /public/shares/:token/items/:item_key` を新設 | 追加のみ |
| E10 | `GET /v1/me.auth_providers` の導出を `password_hash` ベースに変更 | キー・型は不変。値は「email 列だけがある」ケースでのみ変わる（該当ユーザーは存在しない） |
| E11 | レート制限 429 を導入 | 新規の失敗応答が発生しうる |
