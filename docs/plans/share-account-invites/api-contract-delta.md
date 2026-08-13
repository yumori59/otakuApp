# API 契約差分 — share-account-invites

**この文書は `docs/plans/backend-domain-modules/api-contract.md`（基底契約）+ `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md`（第 1 差分）への第 2 差分である。**
先行 2 文書は書き換えない。実装エージェントは **基底契約 + 第 1 差分 + 本差分** を契約の正として扱う。

**ここに書かれたパス・メソッド・JSON キー・enum 値を実装側で勝手に変えない。**
変更が必要なら実装を止めて planner に差し戻すこと（`.claude/rules/02-agents.md`「重要な分離」）。

**状態: 確定**（`questions-requirements.md` Q1〜Q13 回答済み）。
**Q1 = A（公開経路の完全廃止）で確定。`visibility` フィールドは存在しない。**
残る未確定は Q14（トークン URL の入口を iOS に残すか）のみ。本書は 14-a 前提（§4.4 の `redeem` を残す）。

> **後方互換について**: 本差分は例外的に **breaking change を含む**（`/public/shares/:token` の削除、
> `shared_with_account_ids` レスポンスキーの削除）。本番未リリースであり、既存共有は全件失効させる（Q9=9-3）ため許容する。
> **これ以外の破壊的変更は認めない。**

---

## 0. 共通規約への追加

### 0.1 エラーコード（追加）

| code | HTTP | 使う場面 | details |
|---|---|---|---|
| `SHARE_NOT_INVITED` | **403** | `POST /v1/shares/received/redeem` で、トークンは有効だが呼び出しアカウントが招待リストに無い | 無し |
| `SHARE_RECIPIENT_UNKNOWN` | **400** | 招待先 `ACC-XXXXXX` が存在しない | `{ "unknown_account_ids": ["ACC-000000"] }` |
| `SHARE_RECIPIENT_SELF` | **400** | 自分自身の `account_id` を招待した | 無し |

既存コードの用途が増えるもの:

- `SHARE_INVALID` 404 — 「未知 / 失効 / 期限切れ」に加えて **「招待されていないアカウントからの `:id` アクセス」** を含む。**理由を一切区別しない**（NFR-1）
- `VALIDATION_ERROR` 400 — `shared_with_account_ids` が空 / 未指定
- `UNAUTHORIZED` 401 — 共有の閲覧・編集経路が全て Bearer 必須になる

**`SHARE_NOT_INVITED` を返してよいのは `POST /v1/shares/received/redeem` だけ。** 他のどのルートでも使わない
（他所で使うと「その共有 ID は存在する」を confirm してしまう — §4.2 / §4.3 参照）。

### 0.2 enum

**追加・変更なし。**

| 対象 | 値 |
|---|---|
| `permission`（share） | `read` / `write`（変更なし） |
| `scope_type`（share） | `tour` / `identity_summary`（変更なし） |
| `status`（application） | `draft` / `applied` / `won` / `lost` / `cancelled`（変更なし） |

**`visibility` という enum は作らない。** Q1=A により「公開共有」という状態が存在しないため。
（初版の計画では `invited_only` / `link` の 2 値を提案していたが、**却下された**。実装に持ち込まないこと）

### 0.3 レート制限（追加）

| ルート | 上限 | カウント単位 |
|---|---|---|
| `POST /v1/shares` | 30 回 / 分 | userId |
| `POST /v1/shares/:id/recipients` | 30 回 / 分 | userId |
| `POST /v1/shares/received/redeem` | 30 回 / 分 | userId |
| `PATCH /v1/shares/received/:id/items/:item_key` | 60 回 / 分 | userId + share_id |

`POST /v1/shares` / `:id/recipients` の制限は **ACC-ID 列挙の防止**（NFR-2）。
既存 `ThrottleShareWrite`（token 単位 60/分）は**カウント単位を userId + share_id に置き換える**（token がリクエストに現れなくなるため）。
超過時は既存どおり `RATE_LIMITED` 429。

### 0.4 DB（`apps/api/prisma/schema.prisma`）

```prisma
model ShareLink {
  id           String    @id @db.Uuid
  ownerId      String    @map("owner_id") @db.Uuid
  scopeType    String    @map("scope_type")
  scopeId      String?   @map("scope_id") @db.Uuid
  tokenHash    String    @unique @map("token_hash")
  permission   String    @default("read")
  maskMemberNo Boolean   @default(true) @map("mask_member_no")
  // ★ sharedWithAccountIds は削除（FR-5-4）。visibility は追加しない
  expiresAt    DateTime? @map("expires_at") @db.Timestamptz(6)
  revokedAt    DateTime? @map("revoked_at") @db.Timestamptz(6)
  viewCount    Int       @default(0) @map("view_count")
  lastViewedAt DateTime? @map("last_viewed_at") @db.Timestamptz(6)
  editCount    Int       @default(0) @map("edit_count")
  lastEditedAt DateTime? @map("last_edited_at") @db.Timestamptz(6)
  createdAt    DateTime  @default(now()) @map("created_at") @db.Timestamptz(6)
  updatedAt    DateTime  @updatedAt @map("updated_at") @db.Timestamptz(6)

  owner      User             @relation(fields: [ownerId], references: [id], onDelete: Cascade)
  recipients ShareRecipient[] // ★追加

  @@map("share_links")
}

model ShareRecipient {
  id           String    @id @db.Uuid
  shareLinkId  String    @map("share_link_id") @db.Uuid
  /** 招待時に指定された ACC-XXXXXX（表示・照合用のスナップショット） */
  accountId    String    @map("account_id")
  /** 招待時に解決した users.id。実在確認が必須なので NOT NULL（Q4=4-1） */
  userId       String    @map("user_id") @db.Uuid
  /** 受け取り側がこの共有を非表示にした時刻（Q3=3-3）。オーナーには見せない */
  hiddenAt     DateTime? @map("hidden_at") @db.Timestamptz(6)
  /** 受け取り側が最後に board を開いた時刻（未読判定 + オーナー側の表示） */
  lastViewedAt DateTime? @map("last_viewed_at") @db.Timestamptz(6)
  createdAt    DateTime  @default(now()) @map("created_at") @db.Timestamptz(6)
  updatedAt    DateTime  @updatedAt @map("updated_at") @db.Timestamptz(6)

  shareLink ShareLink @relation(fields: [shareLinkId], references: [id], onDelete: Cascade)
  user      User      @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@unique([shareLinkId, accountId])
  @@index([userId])
  @@map("share_recipients")
}
```

`User` モデルに `shareRecipients ShareRecipient[]` を追加すること（Prisma の双方向リレーション要件）。

**設計判断（採用理由と却下案）**:

- **採用: 正規化テーブル `share_recipients`**。受信箱（`GET /v1/shares/received`）は「自分が招待されている共有」の**逆引き**が要る。`user_id` の btree インデックス 1 本で済む
- **却下: `shared_with_account_ids text[]` を ACL に昇格 + GIN インデックス**。マイグレーションは軽いが、①招待ごとの状態（`hidden_at` / `last_viewed_at`）を持てない ②`account_id → user_id` の解決を毎回 `profiles` と結合する必要がある ③配列要素の削除をアトミックに書きにくい
- **却下: `user_id` を nullable にして未登録 ACC-ID の招待を許す**。Q4=4-1（実在確認して弾く）が確定したため不要
- **`sharedWithAccountIds` を削除する理由**: Q1=A により「記録用メタ」という概念自体が無くなった。残すと `share_recipients` との二重管理になり、どちらが正か分からなくなる（Q13 で `docs/10` の記述も消す）

### 0.5 移行（Q9=9-3）

`db push` 後に 1 回だけ実行する:

```sql
update share_links set revoked_at = now() where revoked_at is null;
```

- 既存トークンは全て失効し、`redeem` は 404 `SHARE_INVALID` になる（AC-SI-61）
- 冪等（`where revoked_at is null` により 2 回実行しても上書きしない — AC-SI-62）
- backfill は**しない**。`shared_with_account_ids` の中身は `share_recipients` に移さない（Q9=9-3）

---

## 1. `POST /v1/shares`（変更）

**Bearer 必須（既存どおり）。**

```jsonc
// req
{
  "scope_type": "tour",
  "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
  "permission": "read",                                    // 省略時 "read"（既存）
  "mask_member_no": true,
  "expires_at": "2026-08-31T00:00:00.000Z",
  "shared_with_account_ids": ["ACC-3F9A21", "ACC-9F8E7D"]  // ★必須（1〜20 件）に変更
}
```

```jsonc
// 201
{
  "id": "018f3c2a-1111-7c90-9d2a-000000000001",
  "token": "base64url-opaque-token-shown-once",
  "url": "meigicho://share/base64url-opaque-token-shown-once",   // ★スキーム変更（後述）
  "scope_type": "tour",
  "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
  "permission": "read",
  "mask_member_no": true,
  "recipients": [                                                 // ★追加
    { "account_id": "ACC-3F9A21", "display_name": "ゆう", "invited_at": "2026-08-07T00:00:00.000Z", "last_viewed_at": null },
    { "account_id": "ACC-9F8E7D", "display_name": null,   "invited_at": "2026-08-07T00:00:00.000Z", "last_viewed_at": null }
  ],
  "expires_at": "2026-08-31T00:00:00.000Z",
  "created_at": "2026-08-07T00:00:00.000Z"
}
```

- **`shared_with_account_ids` はレスポンスから削除**（`recipients` が正。二重に持たない）
- **`url` は `https://share.example.com/s/<token>` から `meigicho://share/<token>` に変える。**
  Q1=A で `/public/*` を廃止した結果、https の URL は**開ける先が無くなる**ため。カスタムスキームなら
  アプリがインストールされている端末でのみ意味を持ち、招待済みかどうかは `redeem` が判定する（§4.4）
- 環境変数 `SHARE_URL_BASE` 等でこの prefix を組んでいる場合は同時に更新すること（実装時に grep で確認）

### バリデーション

| 条件 | 応答 |
|---|---|
| `shared_with_account_ids` が未指定 or 空配列 | 400 `VALIDATION_ERROR`（message: `shared_with_account_ids must contain at least one account id`） |
| 要素が `^ACC-[0-9A-F]{6}$` に不一致（小文字含む） | 400 `VALIDATION_ERROR`（既存 `ACCOUNT_ID_RE` を変えない — BE-2） |
| 21 件以上 | 400 `VALIDATION_ERROR`（既存 `ArrayMaxSize(20)`） |
| 重複要素 | **400 にしない**。重複排除して処理（AC-SI-04） |
| 呼び出し元自身の `account_id` を含む | 400 `SHARE_RECIPIENT_SELF` |
| 存在しない `account_id` を含む | 400 `SHARE_RECIPIENT_UNKNOWN` + `details.unknown_account_ids`。**共有は作られない** |
| Free で有効リンク 2 本目 | 403 `PLAN_LIMIT_SHARE`（既存・閾値変更なし） |
| `write` で公演数超過 | 403 `PLAN_LIMIT_SHARE_WRITE`（既存・閾値変更なし） |

**判定順序（契約・この順を変えない / AC-SI-13）**:

```
① DTO 検証（形式・件数）
② self 判定           → SHARE_RECIPIENT_SELF 400
③ 実在確認            → SHARE_RECIPIENT_UNKNOWN 400
④ PLAN_LIMIT_SHARE    → 403
⑤ PLAN_LIMIT_SHARE_WRITE → 403
⑥ 作成（share_links + share_recipients を 1 トランザクションで）
```

③ を ④⑤ より前に置く理由: Free ユーザーが ACC-ID を打ち間違えたときに「共有は 1 本までです」ではなく
「その ID は見つかりません」を先に見せたいため。**逆にすると原因の特定ができない。**

`token` / `url` は従来どおり**このレスポンスにしか現れない**（`GET /v1/shares` には含めない）。

---

## 2. `GET /v1/shares`（変更・オーナー側一覧）

```jsonc
{
  "items": [
    {
      "id": "018f3c2a-1111-7c90-9d2a-000000000001",
      "scope_type": "tour",
      "scope_id": "018f3c2a-dddd-7c90-9d2a-000000000001",
      "scope_name": "STELLARIS LIVE TOUR 2026",
      "permission": "read",
      "mask_member_no": true,
      "recipients": [                                    // ★追加（shared_with_account_ids を置き換え）
        { "account_id": "ACC-3F9A21", "display_name": "ゆう",
          "invited_at": "2026-08-07T00:00:00.000Z",
          "last_viewed_at": "2026-08-07T09:00:00.000Z" }
      ],
      "expires_at": "2026-08-31T00:00:00.000Z",
      "revoked_at": null,
      "view_count": 3,
      "last_viewed_at": "2026-08-07T09:00:00.000Z",
      "created_at": "2026-08-07T00:00:00.000Z",
      "is_active": true
    }
  ]
}
```

- `token` / `token_hash` を含めないのは既存どおり
- `recipients[].display_name` は `profiles.display_name`（無ければ null）
- **`recipients[].hidden_at` は返さない**（Q3: 非表示をオーナーに見せない）
- `shared_with_account_ids` は**削除**

---

## 3. 招待の追加・削除（新規・オーナー側）

### 3.1 `POST /v1/shares/:id/recipients`

```jsonc
// req
{ "account_ids": ["ACC-1A2B3C"] }
// 200
{ "recipients": [ { "account_id": "...", "display_name": "...", "invited_at": "...", "last_viewed_at": null } ] }
```

- レスポンスは**追加後の全件**（差分ではない）
- 既に招待済みの ACC-ID は冪等（重複行を作らず `invited_at` も更新しない — AC-SI-08）
- バリデーションは §1 と同一（形式 / self / unknown / **合計 20 件上限**）
- 他人の `:id` → 404 `NOT_FOUND`（BE-4）
- 失効済み / 期限切れの `:id` → 404 `NOT_FOUND`（AC-SI-11。失効したリンクに招待を足せない）

### 3.2 `DELETE /v1/shares/:id/recipients/:account_id`

- 204。存在しない ACC-ID でも 204（冪等 — AC-SI-09）
- 他人の `:id` → 404 `NOT_FOUND`
- **最後の 1 人を削除しても 204 で許可する**（AC-SI-12）。以後そのリンクは誰も開けない（実質失効）。
  意図して全員外すことはありうるので 400 にしない

---

## 4. 受信箱・board（新規・受け取り側）

**全て Bearer 必須。`@Public()` を付けない。**

### 4.1 `GET /v1/shares/received`

```jsonc
{
  "items": [
    {
      "share_id": "018f3c2a-1111-7c90-9d2a-000000000001",
      "scope_type": "tour",
      "scope_name": "STELLARIS LIVE TOUR 2026",
      "permission": "write",
      "owner": { "account_id": "ACC-7C1D02", "display_name": "みお" },
      "invited_at": "2026-08-07T00:00:00.000Z",
      "expires_at": "2026-08-31T00:00:00.000Z",
      "unread": true
    }
  ]
}
```

- **含めるもの**: 上記キーのみ
- **含めてはいけないもの**（BE-4 / NFR-1 / AC-SI-45）: `token` / `token_hash` / `scope_id` / オーナーの内部 UUID / 他の招待者の ACC-ID / 会員番号 / 申込の中身
- 絞り込み: `revoked_at IS NULL` かつ（`expires_at IS NULL` または `expires_at > now`）かつ `hidden_at IS NULL` かつ `share_links.owner_id <> me`
  - 2026-08-14 追記: `scope_type="tour"` の場合はさらに参照先 tour が `deleted_at IS NULL` であること。オーナーがツアーを削除すると、その行は一覧から除外される（削除前は残っていたが、開くと `SHARE_INVALID` 404 になる不親切な状態だった）
- 並び: `share_recipients.created_at DESC`
- `scope_name`: `scope_type="tour"` ならツアー名（tour は必ず解決できる。未解決＝削除済みの行は一覧に含めないため、tour スコープの行で `scope_name` が null になることはない）、`identity_summary` なら固定文言 `"名義の申込サマリー"`
- `unread` = `share_recipients.last_viewed_at IS NULL OR (share_links.last_edited_at IS NOT NULL AND last_viewed_at < share_links.last_edited_at)`
  - 2026-08-10 修正: 当初は `share_links.updated_at` 基準だったが、`updated_at` は**他の招待者の閲覧**（`view_count` 加算）でも進むため、
    自分は何も見逃していないのに `unread` が true に戻っていた（BE-7）。**編集時にだけ進む `last_edited_at`** を基準にする
  - 「見ていない」= true、「見た後に共有ボードが編集された」= true、それ以外 = false。オーナー側のデータ更新（申込の追加など）は
    `share_links` を触らないので、以前から `unread` の対象外（既知の制約）
- 招待 0 件でも 200 `{ "items": [] }`（AC-SI-46）
- ページングは持たない（1 リンク 20 人・個人利用の規模で不要）

### 4.2 `GET /v1/shares/received/:id`

**レスポンス本体は旧 `GET /public/shares/:token` と完全に同形**（`docs/04-api.md:455-492`）。
マスキング規則・`identity_summary` ペイロード・`history_visible=false` の扱い・`item_key` / `rev` / `editable` の意味論は**一切変えない**（NFR-7）。追加キーのみ:

```jsonc
{
  "share_id": "018f3c2a-1111-7c90-9d2a-000000000001",              // ★追加
  "permission": "write",                                            // ★追加（従来は item の形から推測していた）
  "owner": { "account_id": "ACC-7C1D02", "display_name": "みお" },  // ★追加
  "scope_type": "tour",
  "tour": { "id": "...", "name": "..." },
  "items": [ /* 既存と同一 */ ]
}
```

**判定順序（契約）**:

| # | 条件 | 応答 |
|---|---|---|
| ① | `:id` が存在しない | 404 `SHARE_INVALID` |
| ② | 失効 / 期限切れ | 404 `SHARE_INVALID` |
| ③ | 呼び出し元がオーナー | **通す**（FR-2-6 / AC-SI-23） |
| ④ | `share_recipients` に自分が無い | **404 `SHARE_INVALID`**（403 にしない — Q8 / AC-SI-21） |
| ⑤ | ペイロード組み立て | 旧 `ResolveShareUseCase` の中身を再利用 |

副作用: `share_links.view_count += 1` / `last_viewed_at`（既存どおり）+ `share_recipients.last_viewed_at`（招待経由のときだけ。オーナー閲覧では更新しない）。

`X-Robots-Tag: noindex, nofollow` は**不要になる**（認証必須ルートはクロールされない）。付けても害はないが契約には含めない。

### 4.3 `PATCH /v1/shares/received/:id/items/:item_key`

**リクエスト / レスポンスは旧 `PATCH /public/shares/:token/items/:item_key` と完全に同形。**

```jsonc
// req — status / seat のどちらか一方以上
{ "rev": "opaque", "status": "won", "seat": "1F A列 12番" }
```

**判定順序（契約・この順を変えない / AC-SI-29）**:

| # | 条件 | 応答 |
|---|---|---|
| ① | `:id` 未知 / 失効 / 期限切れ | 404 `SHARE_INVALID` |
| ② | **オーナー本人でなく、かつ招待リストに無い** | **404 `SHARE_INVALID`** |
| ③ | `permission !== "write"` | 403 `FORBIDDEN` |
| ④ | `scope_type !== "tour"` | 403 `FORBIDDEN` |
| ⑤ | ボディ不正 | 400 `VALIDATION_ERROR` |
| ⑥ | `item_key` 不一致 | 404 `SHARE_INVALID` |
| ⑦ | 対象行が `editable:false` | 403 `FORBIDDEN`（理由を区別しない） |
| ⑧ | `rev` 不一致 | 409 `CONFLICT` + `details.current` |

**招待判定（②）は権限判定（③）より前。** 順序を逆にすると、非招待者が 403 を受け取ることで
「このリンクは read だ」＝「そのリンクは存在する」を知れてしまう。

`item_key` / `rev` の HMAC 鍵は**従来どおり `share_links.token_hash`**。addressing が `:token` → `:id` に変わっても
鍵はサーバー内部にあるので変わらない。したがって `share-item-key.ts` / `share-write.ts` は**ロジック変更不要**（移設のみ）。

成功時の副作用は既存どおり（`edit_count += 1` / `last_edited_at`。`view_count` は増やさない）。

### 4.4 `POST /v1/shares/received/redeem`

ディープリンク `meigicho://share/<token>` から開いたときの入口（FR-4-2 / **Q14-a 前提**）。

```jsonc
// req
{ "token": "base64url-opaque-token" }
// 200
{ "share_id": "018f3c2a-1111-7c90-9d2a-000000000001" }
```

| 条件 | 応答 |
|---|---|
| 未知 / 失効 / 期限切れトークン | 404 `SHARE_INVALID`（3 者を区別しない — AC-SI-27） |
| 有効トークン + 招待済み | 200 `{ share_id }` |
| 有効トークン + オーナー本人 | 200 `{ share_id }` |
| 有効トークン + **招待されていない** | **403 `SHARE_NOT_INVITED`**（F2 / AC-SI-26） |

**この 403 は本契約で唯一「存在を confirm する」応答である。** 許容する理由:
トークンは 128bit ランダムで推測不能、呼び出し元は認証済みで追跡可能、
かつ「あなたは招待されていない」と伝えないとユーザーが原因を特定できない（F2 の意図そのもの）。

副作用なし（`view_count` を増やさない。閲覧は §4.2 で計上する）。

### 4.5 `POST /v1/shares/received/:id/hide` / `DELETE /v1/shares/received/:id/hide`

- `POST` → 204。`share_recipients.hidden_at = now()`。受信箱から消える（AC-SI-43）
- `DELETE` → 204。`hidden_at = null`（取り消し）
- 招待されていない `:id` → 404 `SHARE_INVALID`
- オーナー本人（招待行が無い）→ 404 `SHARE_INVALID`（隠す対象の行が無いため）
- 冪等（既に非表示でも 204）

---

## 5. 削除するエンドポイント

| ルート | 変更 |
|---|---|
| `GET /public/shares/:token` | **削除**。到達したら 404（AC-SI-30） |
| `PATCH /public/shares/:token/items/:item_key` | **削除**。到達したら 404（AC-SI-31） |

付随して**必ず**行うこと:

1. `apps/api/src/app.setup.ts` の `GLOBAL_PREFIX_EXCLUDE` から
   `'public/shares/:token'` と `'public/shares/:token/items/:item_key'` の 2 行を削除する。
   **削除し忘れると `/v1/public/shares/:token` という別経路が生えるわけではないが、
   exclude に残った定義が「公開経路がまだある」という誤った contract を示し続ける。**
   AC-SI-32 で `/v1/public/shares/:token` が 404 であることを確認する
2. `apps/api/src/app.module.ts` から `PublicModule` を外す
3. `X-Robots-Tag` を立てていた `ROBOTS_TAG_HEADER` / `ROBOTS_TAG_VALUE` の export は削除してよい（利用者が消えるため）

**削除してはいけないもの**（`apps/api/src/public/` にあるが公開経路とは無関係）:

| ファイル | 移設先 | 理由 |
|---|---|---|
| `public-share.presenter.ts` | `shares/board/` | ペイロード組み立てとマスキングの中核。§4.2 がそのまま使う |
| `identity-summary.service.ts` | `shares/board/` | `scope_type="identity_summary"` の組み立て |
| `shared-applications.service.ts` | `shares/board/` | write 用の `updated_at` 取得・条件付き更新 |
| `share-item-key.ts` | `shares/board/` | `item_key` / `rev` の HMAC |
| `share-write.ts` | `shares/board/` | `editable` の判定 |
| `dto/update-share-item.dto.ts` | `shares/board/dto/` | §4.3 が使う |
| `use-cases/resolve-share.use-case.ts` | `shares/board/use-cases/` | §4.2 の中身になる（token 起点 → link 起点に改修） |
| `use-cases/update-share-item.use-case.ts` | `shares/board/use-cases/` | §4.3 の中身になる（同上） |
| 対応する `*.spec.ts` | 同上 | 既存テストを移設して残す |

---

## 6. iOS 側の契約写し（Network 層のマッピング）

| BE ルート | iOS 呼び出し元 | クライアント |
|---|---|---|
| `POST /v1/shares` | `RemoteShareRepository.create` | `ApiClient` |
| `GET /v1/shares` | `RemoteShareRepository.list` | `ApiClient` |
| `DELETE /v1/shares/:id` | `RemoteShareRepository.revoke` | `ApiClient` |
| `POST /v1/shares/:id/recipients` | `RemoteShareRepository.addRecipients` **新規** | `ApiClient` |
| `DELETE /v1/shares/:id/recipients/:account_id` | `RemoteShareRepository.removeRecipient` **新規** | `ApiClient` |
| `GET /v1/shares/received` | `RemoteSharedInboxRepository.list` **新規** | `ApiClient` |
| `GET /v1/shares/received/:id` | `RemoteSharedBoardRepository.fetchBoard(shareID:)` **変更** | **`ApiClient`**（← `PublicApiClient` から） |
| `PATCH /v1/shares/received/:id/items/:item_key` | `RemoteSharedBoardRepository.updateItem` **変更** | **`ApiClient`** |
| `POST /v1/shares/received/redeem` | `RemoteSharedInboxRepository.redeem(token:)` **新規** | `ApiClient` |
| `POST/DELETE /v1/shares/received/:id/hide` | `RemoteSharedInboxRepository.setHidden` **新規** | `ApiClient` |
| ~~`GET /public/shares/:token`~~ | **削除**（`PublicApiClient` ごと） | — |

### 6.1 `PublicApiClient` 削除にあたっての注意（**IOS-2 の温床**）

`meigicho/Packages/Network/Sources/Network/PublicApiClient.swift` の冒頭コメントは
「共有リンクを受け取った人は自分のアカウントでログインしていない前提であり、公開経路の 401 で
自分のアカウントをログアウトさせてはならない（R7 / AC-SB-13-M）」を**設計意図として明文化**している。

**この前提は Q1=A で完全に消滅する。** 受け取り側は必ずログイン済みであり、
401 → refresh → 失敗 → ログアウトは自分のセッションに対する**想定どおりの挙動**になる。

削除に伴って参照が残る箇所（全て潰すこと）:

| ファイル | 対応 |
|---|---|
| `App/AppEnvironment.swift:27,70` | `publicApiClient` プロパティと生成を削除 |
| `App/AppEnvironment.swift:43,117` | `sharedBoardTokenStore` を削除 |
| `Network/ApiClient.swift:10,67` | 「公開経路はこのクライアントで送らない」コメントと `isVersioned` ガードの見直し |
| `Network/Endpoint.swift:62` | `publicPath` の利用者が `/health` 系のみになる。残すか消すかを実装時に判断（**残す場合はコメントを更新**） |
| `Domain/Repositories/Repositories.swift:91` | `SharedBoardRepository` の「`PublicApiClient` のみを使う」コメントを書き換え |
| `Network/Remote/RemoteShareRepository.swift:8` | 「あちらは `PublicApiClient`」コメントを書き換え |
| `Network/Remote/RemoteSharedBoardRepository.swift:7,16,19` | `ApiClient` へ差し替え |
| `Features/SharedBoard/SharedBoardView.swift:10` | 同コメント |
| `Network/Tests/.../ResponseValidatorTests.swift:53-56` | `PublicApiClient` を使うテストの整理 |
| `Network/Tests/.../RemoteSharedBoardRepositoryTests.swift:5,21` | `ApiClient` ベースに書き換え |

### 6.2 削除する画面の参照（**放置するとテストが落ちる**）

`OpenSharedBoardView.swift` は**広告禁止画面リストに名指しで載っている**:

- `meigicho/Packages/DesignSystem/Tests/DesignSystemTests/AdSlotForbiddenScreensTests.swift:20`
- `meigicho/Packages/Domain/Tests/DomainTests/AdGatekeeperTests.swift:146`

さらに提示元が `meigicho/Packages/Features/Sources/Features/Home/HomeView.swift:97` にある。
**この 3 箇所を同時に処理しないと、ビルドは通ってもテストが落ちるか、死んだシートが残る（IOS-1）。**

### 6.3 エラー写し（`Domain/AppError.swift`）

| envelope code | HTTP | iOS `AppError` |
|---|---|---|
| `SHARE_NOT_INVITED` | 403 | `.shareNotInvited` **新規**。文言「この共有はあなたに共有されていません」 |
| `SHARE_RECIPIENT_UNKNOWN` | 400 | `.shareRecipientUnknown(accountIDs:)` **新規**。文言「見つからないアカウント ID があります: ACC-…」 |
| `SHARE_RECIPIENT_SELF` | 400 | 既存 `.validation` にフォールバックで可（自画面で事前に弾く） |
| `SHARE_INVALID` | 404 | 既存 `.shareInvalid`（挙動変更なし） |

`SHARE_RECIPIENT_UNKNOWN` の `details.unknown_account_ids` を読む箇所は **`RemoteShareRepository` 1 箇所に閉じる**
（既存 `promoteShareItemConflict` と同じ方針 — `RemoteSharedBoardRepository.swift` のコメント参照）。
**`details` が読めなければ格上げしない。**

---

## 7. 契約の非変更点（明示）

以下は**変えない**。実装エージェントが「ついでに」触らないこと。

- マスキング規則（会員番号・`history_visible=false` の `rep_name`「非公開の名義」・`rep_color`/`seat` null・同行者名はマスク対象外）
- `identity_summary` の公開ペイロード形（`visible:false` は件数系キー自体を含めない）
- `item_key` / `rev` の生成方法（HMAC 鍵は `token_hash`）と不透明性
- `CONFLICT` 409 の `details.current = { status, seat, rev }`
- `expires_at` の既定 +30 日 / 上限 +365 日
- `PLAN_LIMIT_SHARE`（Free 有効 1 本）/ `PLAN_LIMIT_SHARE_WRITE`（Free 公演 3 件）の閾値
- `permission` の発行後変更が存在しないこと
- 同期プロトコル（`/v1/sync/*`）— 共有と無関係。触らない
- `POST /v1/webhooks/revenuecat`・`/health`・`/readyz` — `GLOBAL_PREFIX_EXCLUDE` の他の要素を巻き添えで消さない
