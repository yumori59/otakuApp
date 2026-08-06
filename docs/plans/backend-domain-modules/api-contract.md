# API 契約 — backend-domain-modules

**この文書が実装時の契約の正。** 実装エージェントはここに書かれたパス・メソッド・JSON キー・enum 値を勝手に変えない。
変更が必要なら実装を止めて planner に差し戻す（rule 02「API 契約をまたぐ変更を契約未確定のまま委譲しない」）。

docs/04-api.md との差分は §9 に列挙する。

---

## 0. 共通規約

| 項目 | 値 |
|---|---|
| プレフィックス | `/v1`。除外: `/health`・`/readyz`・`/public/shares/:token` |
| 認証 | `Authorization: Bearer <access_token>`。`@Public()` 以外は必須 |
| Content-Type | `application/json` |
| JSON キー | snake_case |
| 日付 | `YYYY-MM-DD`（`@db.Date`）/ 日時は ISO8601 UTC（`2026-07-31T12:05:00.000Z`） |
| ID | UUID（クライアント発行 v7 前提。**サーバーはバージョンを検証しない** — `@IsUUID()`） |
| ページング | `limit`（1〜200、既定 50。範囲外は 400）+ `cursor`（前ページの `next_cursor` を**そのまま**渡す opaque トークン。中身はサーバー実装の詳細で、クライアントは解釈・生成しない。壊れたトークンは `VALIDATION_ERROR` 400） |

### エラー envelope（全エンドポイント共通）

```json
{
  "code": "PLAN_LIMIT_IDENTITY",
  "message": "identity limit reached (limit=3, current=3)",
  "details": { "limit": 3, "current": 3 },
  "request_id": "018f3c2a-9999-7c90-9d2a-000000000001"
}
```

`request_id` はリクエストヘッダ `X-Request-Id` があればその値、無ければサーバー生成 UUID。

### エラーコード一覧（本計画で使うもの）

| code | HTTP | 使う場面 |
|---|---|---|
| `VALIDATION_ERROR` | 400 | DTO 検証失敗・未知 enum 値・範囲外 |
| `UNAUTHENTICATED` | 401 | Bearer 欠落 / access token 不正・期限切れ |
| `AUTH_APPLE_INVALID` | 401 | Apple identity token の検証失敗 |
| `AUTH_REFRESH_INVALID` | 401 | refresh token が未知 / 失効 / 期限切れ |
| `FORBIDDEN` | 403 | 認証済みだが操作が許されない（本計画では未使用の予定） |
| `PLAN_LIMIT_IDENTITY` | 403 | 名義上限超過。`details: { limit, current }` |
| `PLAN_LIMIT_SHARE` | 403 | 共有リンク上限超過。`details: { limit, current }` |
| `NOT_FOUND` | 404 | 自分のリソースとして存在しない（他人のリソース指定を含む） |
| `SHARE_INVALID` | 404 | 共有トークンが未知 / 失効 / 期限切れ |
| `CONFLICT` | 409 | 既存 id への POST |
| `INTERNAL` | 500 | 未知例外 |

### enum 値（**この値以外は 400。黙って別値に落とさない** — BE-2）

| 対象 | 値 |
|---|---|
| `relation` | `self` / `family` / `friend` / `other` |
| `status`（application） | `draft` / `applied` / `won` / `lost` / `cancelled` |
| `plan` | `free` / `plus` |
| `scope_type`（share） | `tour` / `identity_summary` |
| `permission`（share） | `read` |
| `store`（entitlement・読み取りのみ） | `app_store` / `play_store` / `promo` |
| `platform`（device_token・本計画スコープ外） | `ios` |

---

## 1. Auth

### `POST /v1/auth/apple` — Public

```json
// req
{ "identity_token": "eyJraWQiOi...", "nonce": "optional" }
```

```json
// 200
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

- `is_new`: このリクエストで users 行を新規作成したか（iOS の初回オンボーディング分岐用）
- エラー: `AUTH_APPLE_INVALID` 401 / `VALIDATION_ERROR` 400

### `POST /v1/auth/refresh` — Public

```json
// req
{ "refresh_token": "dGhpcy1pcy..." }
```

```json
// 200
{
  "access_token": "eyJ...",
  "refresh_token": "bmV3LXJlZnJlc2g...",
  "expires_in": 3600,
  "token_type": "Bearer"
}
```

- **回転式**: レスポンスの `refresh_token` は必ず新しい値。旧トークンは即失効
- エラー: `AUTH_REFRESH_INVALID` 401

### `POST /v1/auth/logout` — Public

```json
// req
{ "refresh_token": "dGhpcy1pcy..." }
```

- 204 No Content。未知・失効済みでも 204（冪等）

---

## 2. Me（プロフィール / アカウント）

### `GET /v1/me`

```json
// 200
{
  "user": {
    "id": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
    "email": "abc@privaterelay.appleid.com",
    "auth_providers": ["apple"],
    "created_at": "2026-08-01T00:00:00.000Z"
  },
  "profile": {
    "account_id": "ACC-3F9A21",
    "display_name": null,
    "username": "yuya",
    "app_display_name": "参戦名義帳",
    "theme_color": "#0017C1",
    "locale": "ja_JP",
    "timezone": "Asia/Tokyo",
    "onboarded_at": null,
    "created_at": "2026-08-01T00:00:00.000Z",
    "updated_at": "2026-08-01T00:00:00.000Z"
  },
  "entitlement": {
    "plan": "free",
    "expires_at": null,
    "in_grace_period": false,
    "bonus_identity_slots": 0,
    "bonus_expires_at": null,
    "identity_limit": 3,
    "share_limit": 1
  }
}
```

- `auth_providers`: `users.apple_sub` / `google_sub` / `email` の有無から**サーバーが導出**する配列（DB 列は増やさない）
- `identity_limit` / `share_limit` は導出値。`plus` の場合は `null`（無制限を意味する）

### `PATCH /v1/me`

```json
// req（すべて任意。送られたキーのみ更新）
{
  "display_name": "ゆうや",
  "username": "yuya",
  "app_display_name": "参戦名義帳",
  "theme_color": "#0017C1",
  "locale": "ja_JP",
  "timezone": "Asia/Tokyo",
  "onboarded_at": "2026-08-01T09:00:00.000Z"
}
```

- 200 で `GET /v1/me` と同形を返す
- `account_id` / `plan` / `id` などの読み取り専用キーが含まれていたら `VALIDATION_ERROR` 400（`forbidNonWhitelisted: true`）
- `theme_color` は `^#[0-9A-Fa-f]{6}$`。`username` 1〜30 文字。`app_display_name` 1〜30 文字

---

## 3. Identities

| Method | Path |
|---|---|
| GET | `/v1/identities` |
| POST | `/v1/identities` |
| GET | `/v1/identities/:id` |
| PATCH | `/v1/identities/:id` |
| DELETE | `/v1/identities/:id` |

### `GET /v1/identities`

クエリ: `include_deleted`（`true` / `false`、既定 `false`）

```json
// 200
{
  "items": [
    {
      "id": "018f3c2a-aaaa-7c90-9d2a-000000000001",
      "display_name": "自分",
      "relation": "self",
      "color": "#0017C1",
      "joined_on": "2024-04-01",
      "note": null,
      "history_visible": true,
      "sort_order": 0,
      "created_at": "2026-08-01T00:00:00.000Z",
      "updated_at": "2026-08-01T00:00:00.000Z",
      "deleted_at": null
    }
  ]
}
```

並び: `sort_order asc, created_at asc`。

### `POST /v1/identities` → 201

```json
// req
{
  "id": "018f3c2a-aaaa-7c90-9d2a-000000000001",
  "display_name": "自分",
  "relation": "self",
  "color": "#0017C1",
  "joined_on": "2024-04-01",
  "note": null,
  "history_visible": true,
  "sort_order": 0
}
```

- 必須: `id` / `display_name`
- 既定: `relation="other"` / `color="#0017C1"` / `history_visible=false` / `sort_order=0`
- 制約: `display_name` 1〜60 / `note` ≤2000 / `color` は 6桁 hex
- 201 のボディは GET の 1 要素と同形
- エラー: `PLAN_LIMIT_IDENTITY` 403 / `CONFLICT` 409 / `VALIDATION_ERROR` 400

### `PATCH /v1/identities/:id`

POST と同じフィールド（`id` を除く、すべて任意）。200 で更新後を返す。

### `DELETE /v1/identities/:id`

204。ソフトデリート。既に削除済みでも 204（冪等）。

---

## 4. Memberships

| Method | Path |
|---|---|
| GET | `/v1/memberships?identity_id=` |
| POST | `/v1/memberships` |
| GET | `/v1/memberships/:id` |
| PATCH | `/v1/memberships/:id` |
| DELETE | `/v1/memberships/:id` |

### レスポンス要素

```json
{
  "id": "018f3c2a-bbbb-7c90-9d2a-000000000001",
  "identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000001",
  "fan_club_name_raw": "STELLARIS OFFICIAL FAN CLUB",
  "member_no_last4": "4821",
  "rank": "プレミアム",
  "renewal_on": "2026-09-15",
  "fee_yen": 5500,
  "auto_renew": false,
  "note": null,
  "created_at": "2026-08-01T00:00:00.000Z",
  "updated_at": "2026-08-01T00:00:00.000Z",
  "deleted_at": null
}
```

### `POST /v1/memberships` → 201

必須: `id` / `identity_id` / `fan_club_name_raw`。

- `member_no_last4`: 1〜4 文字の英数のみ。**`member_no` / `member_no_cipher` は受理しない**（送られたら 400）
- `fee_yen`: 0〜1,000,000
- `fan_club_name_raw`: 1〜200
- `rank`: ≤50
- `owner_id` はサーバーが親 identity から設定（リクエストで受け取らない）
- エラー: 親 identity が自分のものでない → `NOT_FOUND` 404
- 既存 `id` の再 POST は `CONFLICT` 409（ソフトデリート済みの id も同じ）

`GET /v1/memberships` は `?identity_id=` 未指定なら自分の全件。並びは `renewal_on asc nulls last, created_at asc`。

### `PATCH /v1/memberships/:id`

`identity_id` の付け替えを許可する（移動先 identity も所有検証。他人のものなら `NOT_FOUND` 404）。
- `identity_id` を付け替えると、この membership を `rep_membership_id` として参照している未削除 application のうち `rep_identity_id` が移動先と一致しないものは、同一 TX で `rep_membership_id` が `null` に**自動クリア**される（FR-AP-4 の不変条件を保つため）。

---

## 5. Tours

| Method | Path |
|---|---|
| GET | `/v1/tours` |
| GET | `/v1/tours/:id` |
| PATCH | `/v1/tours/:id` |
| DELETE | `/v1/tours/:id` |
| GET | `/v1/tours/:id/matrix` |

```json
// tour 要素
{
  "id": "018f3c2a-dddd-7c90-9d2a-000000000001",
  "name": "STELLARIS LIVE TOUR 2026",
  "artist_name_raw": "STELLARIS",
  "created_at": "2026-08-01T00:00:00.000Z",
  "updated_at": "2026-08-01T00:00:00.000Z",
  "deleted_at": null
}
```

- `POST /v1/tours` は**提供しない**（作成経路は `POST /v1/applications` の find-or-create のみ）
- `PATCH` で変更可能なのは `name` / `artist_name_raw`。`name` 変更で既存同名 tour と衝突したら `CONFLICT` 409
- `DELETE` はソフトデリート。配下 events / applications は連鎖させない（requirements C4）

### `GET /v1/tours/:id/matrix`

```json
// 200
{
  "tour_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
  "tour_name": "STELLARIS LIVE TOUR 2026",
  "rows": [
    {
      "event_id": "018f3c2a-eeee-7c90-9d2a-000000000001",
      "event_name": "大阪公演 Day1",
      "venue_name": "大阪城ホール",
      "event_date": "2026-08-20",
      "application_id": "018f3c2a-cccc-7c90-9d2a-000000000001",
      "round_name": "FC1次",
      "status": "applied",
      "seat_raw": null,
      "result_on": "2026-07-20",
      "rep_identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000001",
      "rep_name": "自分",
      "rep_color": "#0017C1",
      "companion_names": ["妹"]
    }
  ]
}
```

- 対象は `deleted_at is null` の event / application のみ
- 並び: `event_date asc nulls last, event_name asc`
- `companion_names` は **配列**（docs/04 の `"妹"` 文字列連結から変更 — §9 D3）
- `venue_name` は `events.venue_name_raw`（マスタ未実装のため coalesce 相手なし）

---

## 6. Events

| Method | Path |
|---|---|
| GET | `/v1/events?tour_id=` |
| GET | `/v1/events/:id` |
| PATCH | `/v1/events/:id` |
| DELETE | `/v1/events/:id` |

```json
// event 要素
{
  "id": "018f3c2a-eeee-7c90-9d2a-000000000001",
  "tour_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
  "name": "大阪公演 Day1",
  "venue_name_raw": "大阪城ホール",
  "event_date": "2026-08-20",
  "starts_at": "2026-08-20T11:00:00.000Z",
  "created_at": "2026-08-01T00:00:00.000Z",
  "updated_at": "2026-08-01T00:00:00.000Z",
  "deleted_at": null
}
```

- `POST /v1/events` は**提供しない**（作成経路は applications の find-or-create）
- `PATCH` 可能: `name` / `venue_name_raw` / `event_date` / `starts_at`。`tour_id` の付け替えは不可（400）

---

## 7. Applications

| Method | Path |
|---|---|
| GET | `/v1/applications` |
| POST | `/v1/applications` |
| GET | `/v1/applications/:id` |
| PATCH | `/v1/applications/:id` |
| DELETE | `/v1/applications/:id` |

### application 要素（レスポンス共通形）

```json
{
  "id": "018f3c2a-cccc-7c90-9d2a-000000000001",
  "tour_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
  "event_id": "018f3c2a-eeee-7c90-9d2a-000000000001",
  "rep_identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000001",
  "rep_membership_id": "018f3c2a-bbbb-7c90-9d2a-000000000001",
  "round_name": "FC1次",
  "applied_on": "2026-07-01",
  "result_on": "2026-07-20",
  "status": "applied",
  "seat_raw": null,
  "ticket_count": 2,
  "price_yen": 16000,
  "note": null,
  "companions": [
    {
      "id": "018f3c2a-ffff-7c90-9d2a-000000000001",
      "identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000002",
      "display_name": "妹",
      "position": 0
    }
  ],
  "created_at": "2026-07-31T12:05:00.000Z",
  "updated_at": "2026-07-31T12:05:00.000Z",
  "deleted_at": null
}
```

`companions` は `position asc` で、`deleted_at is null` のみ。

### `POST /v1/applications` → 201

```json
// req
{
  "id": "018f3c2a-cccc-7c90-9d2a-000000000001",
  "tour": {
    "id": "018f3c2a-dddd-7c90-9d2a-000000000001",
    "name": "STELLARIS LIVE TOUR 2026",
    "artist_name_raw": "STELLARIS"
  },
  "event": {
    "id": "018f3c2a-eeee-7c90-9d2a-000000000001",
    "name": "大阪公演 Day1",
    "venue_name_raw": "大阪城ホール",
    "event_date": "2026-08-20",
    "starts_at": "2026-08-20T11:00:00.000Z"
  },
  "rep_identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000001",
  "rep_membership_id": "018f3c2a-bbbb-7c90-9d2a-000000000001",
  "round_name": "FC1次",
  "applied_on": "2026-07-01",
  "result_on": "2026-07-20",
  "status": "applied",
  "seat_raw": null,
  "ticket_count": 2,
  "price_yen": 16000,
  "note": null,
  "companions": [
    {
      "id": "018f3c2a-ffff-7c90-9d2a-000000000001",
      "identity_id": "018f3c2a-aaaa-7c90-9d2a-000000000002",
      "display_name": "妹",
      "position": 0
    }
  ]
}
```

トランザクション内の順序（`api-contract` の正）:

1. `tour`: `where { ownerId_name: { ownerId, name } }` で検索
   - 見つかり `deletedAt != null` → `deletedAt: null` + `artistNameRaw` 更新で復活
   - 見つからない → `dto.tour.id`（省略時サーバー生成 UUID）で作成
2. `event`: `where { id: dto.event.id }` で upsert（`ownerId` / `tourId` はサーバー設定。update は `name` / `venue_name_raw` / `event_date` / `starts_at` / `deletedAt: null`）
   - 既存 event が**他人のもの**なら `NOT_FOUND` 404 で TX ロールバック
3. `rep_identity_id` の所有・未削除を検証（不正なら 404）
4. `rep_membership_id` があれば所有・未削除かつ `identity_id === rep_identity_id` を検証（不正なら 404）
5. `companions[].identity_id` が非 null なら所有・未削除を検証（不正なら 404）
6. `application` + `companions` を作成

制約:

- `tour.name` 1〜200 必須 / `event.name` 1〜200 必須
- `companions` は 0〜**3** 件。`identity_id` の重複は 400
- `ticket_count` 1〜20（既定 1）/ `price_yen` 0〜10,000,000 / `note` ≤2000
- `status` 省略時 `applied`
- 既存 `id` の再 POST は `CONFLICT` 409（TX 内で検出）

### `GET /v1/applications`

クエリ: `status`（enum・複数可 `status=applied&status=won`）/ `tour_id` / `event_id` / `rep_identity_id` / `limit` / `cursor` / `include_deleted`

```json
// 200
{
  "items": [ /* application 要素 */ ],
  "next_cursor": "2026-07-31T12:05:00.000Z|018f3c2a-cccc-7c90-9d2a-000000000001",
  "has_more": false
}
```

並び: `updated_at asc, id asc`（カーソルページング用）。`next_cursor` は `(updated_at, id)` の複合 opaque トークンで、`updated_at` が同値の行を境界で取りこぼさない。

### `PATCH /v1/applications/:id`

変更可能: `rep_identity_id` / `rep_membership_id` / `round_name` / `applied_on` / `result_on` / `status` / `seat_raw` / `ticket_count` / `price_yen` / `note` / `companions`。
`event_id` / `tour_id` の付け替えは不可（400）。

- `companions` を渡した場合は**全置換**: リクエストに無い既存 companion は `deleted_at` を立て、ある id は更新、新規 id は作成。最大 3 件は維持。**ソフトデリート済みの companion と同じ id を再送した場合は復活（`deleted_at` を `null` に戻す）**
- `companions` キー自体が無ければ companions は変更しない
- `rep_identity_id` だけを変更したとき、既存の `rep_membership_id` が新しい代表名義に属していなければ `rep_membership_id` は `null` に**自動クリア**される（400 にはしない）。属していればそのまま維持する
- 200 で更新後の application 要素を返す

### `DELETE /v1/applications/:id`

204。application と配下 companions をソフトデリート。

---

## 8. Shares / Public

### `POST /v1/shares` → 201

```json
// req
{
  "scope_type": "tour",
  "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
  "mask_member_no": true,
  "expires_at": "2026-08-31T00:00:00.000Z",
  "shared_with_account_ids": ["ACC-3F9A21"]
}
```

```json
// 201
{
  "id": "018f3c2a-1111-7c90-9d2a-000000000001",
  "token": "base64url-opaque-token-shown-once",
  "url": "https://share.example.com/s/base64url-opaque-token-shown-once",
  "scope_type": "tour",
  "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
  "permission": "read",
  "mask_member_no": true,
  "shared_with_account_ids": ["ACC-3F9A21"],
  "expires_at": "2026-08-31T00:00:00.000Z",
  "created_at": "2026-08-01T00:00:00.000Z"
}
```

- `id` はサーバー生成（クライアント発行 id は受けない）
- `scope_type="tour"` → `scope_id` 必須・自分の未削除 tour。`scope_type="identity_summary"` → `scope_id` は送ってはいけない（送られたら 400）
- `expires_at` 省略 → +30 日。上限 +365 日
- `shared_with_account_ids`: 0〜20 件、各 `^ACC-[0-9A-F]{6}$`
- `url` は `${SHARE_BASE_URL}/s/${token}`
- エラー: `PLAN_LIMIT_SHARE` 403 / `NOT_FOUND` 404 / `VALIDATION_ERROR` 400

### `GET /v1/shares`

```json
// 200
{
  "items": [
    {
      "id": "018f3c2a-1111-7c90-9d2a-000000000001",
      "scope_type": "tour",
      "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
      "scope_name": "STELLARIS LIVE TOUR 2026",
      "permission": "read",
      "mask_member_no": true,
      "shared_with_account_ids": ["ACC-3F9A21"],
      "expires_at": "2026-08-31T00:00:00.000Z",
      "revoked_at": null,
      "view_count": 3,
      "last_viewed_at": "2026-08-02T10:00:00.000Z",
      "created_at": "2026-08-01T00:00:00.000Z",
      "is_active": true
    }
  ]
}
```

- **`token` / `token_hash` は含めない**
- `scope_name`: tour の場合は tour 名、`identity_summary` は `null`
- `is_active`: `revoked_at is null && (expires_at is null || expires_at > now())` の導出値
- 並び: `created_at desc`

### `DELETE /v1/shares/:id`

204。`revoked_at = now()`。既に失効済みでも 204。他人の id は 404。

### `GET /public/shares/:token` — Public

`scope_type = "tour"`:

```json
{
  "scope_type": "tour",
  "tour": {
    "name": "STELLARIS LIVE TOUR 2026",
    "artist_name": "STELLARIS"
  },
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

`scope_type = "identity_summary"`:

```json
{
  "scope_type": "identity_summary",
  "generated_at": "2026-08-02T10:00:00.000Z",
  "items": [
    { "name": "自分", "visible": true, "application_count": 12, "won_count": 5 },
    { "name": "友人A", "visible": false }
  ]
}
```

マスキング規則（**必ず守る**）:

| 条件 | 挙動 |
|---|---|
| `identities.history_visible = false`（tour スコープ） | `rep_name` を `"非公開の名義"`、`rep_color` を `null`、`seat` を `null` にする |
| `identities.history_visible = false`（identity_summary スコープ） | `name` は出すが `visible: false` とし件数系キーを含めない |
| 全スコープ共通 | 会員番号・`owner_id`・`account_id`・`shared_with_account_ids`・内部 UUID（identity_id / application_id 等）を**一切含めない** |
| 同行者 | `identity_id` があればその identity の現在の `display_name`、無ければ companion の `display_name` |

- 有効な閲覧時のみ `view_count += 1` / `last_viewed_at = now()`
- 無効（未知 / `revoked_at` あり / `expires_at <= now()`）は一律 `SHARE_INVALID` 404
- レスポンスヘッダに `X-Robots-Tag: noindex, nofollow` を付ける（docs/09 L3）
- CORS は `CORS_ORIGINS`（共有 Web オリジン）に対して `GET, OPTIONS` のみ

---

## 9. docs/04-api.md との差分（実装後に docs を更新する）

| # | 差分 | 理由 |
|---|---|---|
| D1 | `/v1/me`（GET / PATCH）を新設 | docs/04 に契約が無い。`profiles.account_id` / `username` / `app_display_name` / `theme_color`（docs/10 M3・M4）を扱う経路が必要 |
| D2 | `GET /v1/shares` / `DELETE /v1/shares/:id` を新設 | docs/04 は発行と公開解決のみ。失効操作は docs/09 1-6 に要件があるが契約が無い |
| D3 | matrix の `companion_names` を文字列連結 → **配列** | docs/04 は `"妹"`（`string_agg` 由来）。クライアントで区切り文字を解析させない。共有ペイロードの `companions` も配列で統一 |
| D4 | `POST /v1/auth/refresh` が `refresh_token` も返す | 回転式（`questions-requirements.md` Q2）。docs/04 は access のみ |
| D5 | `POST /v1/auth/apple` のレスポンスに `account_id` / `is_new` を追加 | iOS のオンボーディング分岐とアカウントID表示に必要 |
| D6 | `POST /v1/shares` が `shared_with_account_ids` を受理 | docs/10 M8 / `schema.prisma:194` に列があるが docs/04 の req に無い |
| D7 | `POST /v1/memberships` から `fan_club_id` / `member_no_cipher` を削除 | マスタ表と暗号化列を Phase 1 で作らない（Q1） |
| D8 | `GET /v1/tours/:id/matrix` を DB ビューではなく Prisma クエリで実装 | requirements C2 |
| D9 | `POST /v1/tours` / `POST /v1/events` を提供しない | 作成経路を applications の find-or-create に一本化（docs/04 §1.3「主経路はapplicationsのfind-or-create」に沿う） |
| D10 | `identity_summary` 共有の payload 形を確定 | docs/03 §6.5 の SQL にはあるが docs/04 §3.7 に JSON 例が無い |
| D11 | `cursor` を `updated_at` 単体 → `(updated_at, id)` の複合 opaque トークンに変更 | docs/04 §3.6 / 旧契約は ISO8601 単体。`updated_at` 同値の行が limit 境界でまるごとスキップされる（レビュー 中-3）。`/v1/sync` を実装するときも同じ形にそろえる |
