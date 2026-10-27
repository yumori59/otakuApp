# API 契約差分 — avatar-upload

**本書は次への追記差分である。基底のファイルは書き換えない。**

1. `docs/plans/backend-domain-modules/api-contract.md`（基底契約。`GET/PATCH /v1/me` は §2）
2. `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md`
3. `docs/plans/account-deletion/api-contract-delta.md`（`DELETE /v1/me`）
4. `docs/plans/share-account-invites/api-contract-delta.md`

実装エージェント（`nest-developer` / `swift-developer`）は **基底契約 + 上記差分 + 本書**を契約の正として扱い、
パス・メソッド・JSON キー・ステータス・エラーコード・フィールド名を勝手に変えない。変更が必要なら実装を止めて planner に差し戻す（rule 02）。

**後方互換**: 既存レスポンスへの**キー追加 1 つ**（`profile.avatar_url`）と**新規 2 ルート**のみ。既存キー・既存ルートの意味は変えない。

---

## 0. 共通規約への追加

### 0.1 Content-Type の例外

基底 §0 の「Content-Type: `application/json`」に対し、**`PUT /v1/me/avatar` のリクエストのみ `multipart/form-data`**。
レスポンスは従来どおり `application/json`。

### 0.2 エラーコード（**新規 3 つ**）

`apps/api/src/common/errors/error-codes.ts` の `ErrorCode` / `ERROR_CODE_STATUS` に追加し、
`errorCodeFromStatus` にも 413 / 415 / 503 の写像を追加する（multer や Express の body parser が投げる標準例外も同じコードになる）。

| code | HTTP | 意味 |
|---|---|---|
| `PAYLOAD_TOO_LARGE` | 413 | リクエスト（ファイル）がサイズ上限を超えた。本機能では 5MiB 超 |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | 受理しないファイル形式。本機能では JPEG / PNG 以外（HEIC を含む） |
| `SERVICE_UNAVAILABLE` | 503 | 依存先の設定・準備が整っておらず機能が一時的に使えない。本機能ではストレージ未設定 / `user_avatars` テーブル未作成 |

`details` はいずれも `null`。`message` は固定文字列（下表）。**ファイル名・URL・オブジェクトキー・内部例外の文言を載せない**。

| 状況 | code | message（固定） |
|---|---|---|
| 5MiB 超 | `PAYLOAD_TOO_LARGE` | `file too large (max 5242880 bytes)` |
| JPEG/PNG 以外 | `UNSUPPORTED_MEDIA_TYPE` | `unsupported image type (jpeg or png only)` |
| `file` 欠落・非 multipart | `VALIDATION_ERROR` | `file is required` |
| 複数ファイル・未知フィールド・`file` 以外の名前のファイル | `VALIDATION_ERROR` | （multer 由来の Nest 標準メッセージのまま可） |
| デコード不能・ピクセル上限超過 | `VALIDATION_ERROR` | `invalid image` |
| ストレージ未設定 / テーブル未作成 | `SERVICE_UNAVAILABLE` | `avatar is temporarily unavailable` |

### 0.3 レート制限（既存表に追加）

| ルート | 上限 | カウント単位 |
|---|---|---|
| `PUT /v1/me/avatar` | 10 回 / 5 分 | userId（既存 `ThrottleAuthUser()` = `AUTH_USER` throttler を再利用。バケットはルート単位で独立） |
| `DELETE /v1/me/avatar` | 10 回 / 5 分 | 同上 |

### 0.4 環境変数（**新規 3 つ。すべて非機密**）

| 変数 | 本番値 | ローカル（docker-compose） | 未設定時 |
|---|---|---|---|
| `AVATAR_BUCKET` | `<project_id>-avatars`（Terraform 出力） | `meigicho-avatars-local` | **機能無効**: `PUT` は 503、`avatar_url` は常に `null` |
| `AVATAR_PUBLIC_BASE_URL` | `https://storage.googleapis.com/<AVATAR_BUCKET>` | `http://localhost:4443/meigicho-avatars-local` | `https://storage.googleapis.com/<AVATAR_BUCKET>` |
| `GCS_API_ENDPOINT` | **設定しない**（空） | `http://gcs:4443` | 本物の GCS（`storage.googleapis.com`）に ADC で接続 |

認証情報の環境変数は**追加しない**。本番は Cloud Run 実行 SA（`meigicho-api`）の ADC、ローカルは `GCS_API_ENDPOINT` 指定時に認証を行わない（fake-gcs-server）。

---

## 1. `GET /v1/me`（変更: `profile.avatar_url` 追加）

```json
// 200
{
  "user": { "...": "（変更なし）" },
  "profile": {
    "account_id": "ACC-3F9A21",
    "display_name": null,
    "username": "yuya",
    "app_display_name": "参戦名義帳",
    "theme_color": "#0017C1",
    "locale": "ja_JP",
    "timezone": "Asia/Tokyo",
    "onboarded_at": null,
    "avatar_url": "https://storage.googleapis.com/meigicho-prod-avatars/avatars/6f1c2d3e-4b5a-4c6d-8e7f-9a0b1c2d3e4f.jpg",
    "created_at": "2026-08-01T00:00:00.000Z",
    "updated_at": "2026-08-01T00:00:00.000Z"
  },
  "entitlement": { "...": "（変更なし）" }
}
```

| キー | 型 | 規則 |
|---|---|---|
| `profile.avatar_url` | `string \| null` | **常に出力する**（キー省略しない）。未設定・ストレージ未設定・`user_avatars` 未作成のときは `null`。設定済みなら `AVATAR_PUBLIC_BASE_URL + "/" + object_key` の絶対 URL。**認証なしで GET できる**。URL はアップロードごとに変わる（同じ URL の中身は不変） |

- `PATCH /v1/me` の 200 応答も同じ `MeView` なので同じキーが付く（`PATCH` のリクエストに `avatar_url` は**追加しない**。送ると従来どおり `forbidNonWhitelisted` で 400）
- 署名付き URL ではないので期限は無い。クライアントは URL 文字列をキャッシュキーにしてよい

---

## 2. `PUT /v1/me/avatar` — 新規

本人のアバターを設定する（既にあれば置き換える）。

### リクエスト

```
PUT /v1/me/avatar
Authorization: Bearer <access_token>
Content-Type: multipart/form-data; boundary=<boundary>

--<boundary>
Content-Disposition: form-data; name="file"; filename="avatar.jpg"
Content-Type: image/jpeg

<binary>
--<boundary>--
```

| 項目 | 規則 |
|---|---|
| パート | **ファイルパート `file` を 1 つだけ**。それ以外のフィールド・ファイルは 400 |
| `filename` | 任意。サーバーは使わない |
| パートの `Content-Type` | 任意。**サーバーは信用しない**（マジックバイトで判定） |
| 受理形式 | JPEG（`FF D8 FF`）/ PNG（`89 50 4E 47 0D 0A 1A 0A`） |
| サイズ | ファイルパートが **5,242,880 バイト以下** |
| ピクセル数 | 幅 × 高さ ≤ 16,777,216（4096²） |

### サーバー処理（契約として固定する振る舞い）

1. ストレージ設定と `user_avatars` テーブルの存在を確認（無ければ 503。**アップロード前に**判定）
2. マジックバイト判定 → デコード → EXIF 向き適用 → 中央正方形クロップ → 512×512 → JPEG（品質 85・プログレッシブ無し・メタデータ無し）。透過は白背景で合成
3. オブジェクトキー `avatars/<UUID v4>.jpg` で保存。`Content-Type: image/jpeg`、`Cache-Control: private, max-age=31536000, immutable`
4. `user_avatars` を upsert（`object_key` を新キーに）。旧キーがあれば保存後に削除（ベストエフォート）

> オブジェクトキーの UUID は**エンティティ ID ではない**（DB 行の主キーではなく、推測不能性のための乱数）。
> プロジェクト規約の「ID は UUID v7 クライアント発行」の対象外で、v7 は先頭が時刻のため推測困難性が下がるので使わない。

### レスポンス

| ステータス | 本文 |
|---|---|
| 200 | `MeView`（`GET /v1/me` と同形。`profile.avatar_url` は新 URL） |

### エラー

| code | HTTP | 条件 |
|---|---|---|
| `VALIDATION_ERROR` | 400 | `file` 欠落 / 非 multipart / 余計なパート / デコード不能 / ピクセル上限超過 |
| `UNAUTHENTICATED` | 401 | Bearer 欠落・不正 |
| `NOT_FOUND` | 404 | 処理中にアカウントが削除された（upsert の FK 違反 `P2003` / プロフィール無し） |
| `PAYLOAD_TOO_LARGE` | 413 | 5MiB 超 |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | JPEG / PNG 以外 |
| `RATE_LIMITED` | 429 | §0.3 |
| `INTERNAL` | 500 | ストレージ保存失敗 / DB 更新失敗（**どちらも旧アバターはそのまま残る**） |
| `SERVICE_UNAVAILABLE` | 503 | ストレージ未設定 / `user_avatars` テーブル未作成 |

---

## 3. `DELETE /v1/me/avatar` — 新規

本人のアバターを削除する。**冪等**。

### リクエスト

ボディ無し。ハンドラは `@Body()` を宣言しない（送られても読まずに無視する。対象ユーザーを指定する経路を作らないため）。

### レスポンス

| ステータス | 本文 |
|---|---|
| 200 | `MeView`（`profile.avatar_url: null`）。**未設定だった場合も 200** |

### エラー

| code | HTTP | 条件 |
|---|---|---|
| `UNAUTHENTICATED` | 401 | Bearer 欠落・不正 |
| `NOT_FOUND` | 404 | ユーザーが存在しない（`GET /v1/me` と同じ） |
| `RATE_LIMITED` | 429 | §0.3 |
| `SERVICE_UNAVAILABLE` | 503 | `user_avatars` テーブル未作成 |

ストレージ未設定（`AVATAR_BUCKET` 空）のときは DB 行のみ削除して 200（オブジェクト削除はスキップし警告ログ）。
オブジェクト削除の失敗・404 は 200 のまま（警告ログ。404 はログ不要）。

---

## 4. `DELETE /v1/me`（アカウント削除）への追加の振る舞い

契約（ステータス・ボディ）は**変更なし**。内部の振る舞いのみ追加:

- 削除トランザクションの**前に** `user_avatars.object_key` を読み（テーブル不在なら `null`）、トランザクション成功**後に**オブジェクトを削除する（ベストエフォート。失敗しても 204）
- DB 行は `user_avatars.user_id → users.id ON DELETE CASCADE` で消える。`MeService.deleteAccount` の削除順序配列（`EXPECTED_DELETE_ORDER`）には**追加しない**（テーブル未作成の本番で `deleteMany` が `P2021` を投げてアカウント削除が壊れるため）

---

## 5. iOS 側の対応（Networking / Domain）

| 層 | 変更 |
|---|---|
| `Networking/DTO/MeDTO.swift` | `MeProfileResponse.avatarURL: String?`（`CodingKeys` `avatar_url`）。`Optional` なのでキー欠落でもデコード成功 |
| `Networking/Endpoint.swift` | `contentType: String`（既定 `"application/json"`）を追加し、`body` があるときにその値を `Content-Type` に設定 |
| `Networking/MultipartFormData.swift`（新規） | 単一ファイルパートの body と `multipart/form-data; boundary=...` を生成 |
| `Networking/Remote/RemoteProfileRepository.swift` | `uploadAvatar(jpegData:)` → `PUT /me/avatar`、`deleteAvatar()` → `DELETE /me/avatar`。どちらも `MeResponse` をデコードして `toDomain()` |
| `Domain/Models/AccountModels.swift` | `UserProfile.avatarURL: URL?` |
| `Domain/Repositories/Repositories.swift` | `ProfileRepository` に `uploadAvatar(jpegData: Data) async throws -> MeSnapshot` / `deleteAvatar() async throws -> MeSnapshot` |
| `Domain/AppError.swift` | `from(envelope:)` に `PAYLOAD_TOO_LARGE` → `.payloadTooLarge`、`UNSUPPORTED_MEDIA_TYPE` → `.unsupportedMediaType`、`SERVICE_UNAVAILABLE` → `.serviceUnavailable` を追加し、`userMessage` に日本語文言を定義 |

`userMessage` の文言（固定）:

| case | 文言 |
|---|---|
| `.payloadTooLarge` | 画像のサイズが大きすぎます（5MB まで） |
| `.unsupportedMediaType` | この形式の画像は使えません |
| `.serviceUnavailable` | ただいまこの機能を利用できません。時間をおいて再度お試しください |

---

## 6. `docs/04-api.md` への反映

T-DOC で `docs/04-api.md` の Me 節に §1〜§3 を転記する（本書が正、04 は要約）。
